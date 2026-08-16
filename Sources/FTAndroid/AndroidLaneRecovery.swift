// run 開始時に、プロファイルが要求している仮想 Android デバイスのうち起動していないもの
// (=死んだレーン)を先に起こす。ProfileRunner.swift / ApiRunCommand.swift の buildAndroidWorkers
// 直前(GPU 復帰の後)から呼ぶ。両モード共通(performanceMode の有無に関わらず常に試みる) ——
// モードの違いは「復活できなかったレーンをどう扱うか」(FTCore.LaneGate 側の責務)だけ。

import Foundation
import FTCore

public enum AndroidLaneRecovery {

    /// 1台のブート再試行上限。**根拠**: エミュレータのコールドブートは正常時でも数十秒〜1分
    /// かかり(DeviceBooter.startEmulator → waitForAndroidBoot の実測値)、失敗の大半は
    /// 起動直後のポート採番競合や emulator プロセスの一過性の起動不良で、1〜2回の再試行で
    /// 解消することが多い。3回目でも失敗する個体は一過性でない可能性が高く、これ以上の
    /// 再試行は run 開始を徒に延ばすだけなので打ち切る。**支払う時間は失敗の型で違う**:
    /// AVD 名の誤り等の即死は `startEmulator` がプロセスの終了を見て数秒で返す(3回でも約6秒)。
    /// 起動はしたが adb に出てこない型だけが期限切れ(60秒)×3を払う。
    /// 参考: 実行中のワーカー復帰は `RunOrchestrator.MAX_WORKER_REVIVES`(=2)が同じ性質の
    /// 予算を持つ(あちらは実行中のワーカー再構築、こちらは run 開始前のプロセス起動という
    /// 違いはあるが、どちらも「暴走させず・かつ一過性の失敗は救う」という同じ判断軸)。
    /// **尽きたときの発話**: `bootMissingDevices` が最後のエラーを添えて
    /// "could not be revived after N attempt(s)" をログする。performanceMode ではこの後
    /// `FTCore.LaneGate` が run 開始前エラーへ格上げする。
    static let maxBootAttempts = 3

    /// 起動していない仮想 Android デバイスを列挙する。**デバイス不要の純粋関数**
    /// (実機は起動の概念が無い/avd 未指定は起動引数を組めないので対象外。入力順を保つ)。
    /// `runningAVDIDs` は `AndroidDeviceCatalog.canonicalAVDID` と同じ正規化形の集合を渡すこと
    /// (呼び出し側は `AndroidDeviceCatalog.runningAVDs().values` をそのまま渡せる)。
    public static func plan(
        devices: [ResolvedDevice], runningAVDIDs: Set<String>
    ) -> [(device: ResolvedDevice, avdID: String)] {
        devices.compactMap { device in
            guard device.platform == "android", !device.spec.isPhysical,
                  let avd = device.spec.avd else { return nil }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            guard !runningAVDIDs.contains(avdID) else { return nil }
            return (device, avdID)
        }
    }

    /// plan の対象を**1台ずつ直列に**起こす。失敗は非致命(ログして次へ)。
    ///
    /// **必ず1台ずつ直列**: 複数台の同時ブート描画は画面凍結の契機そのもの
    /// (`AndroidGpuRecovery` と `AndroidDataWiper` が同じ理由で直列に処理している。実測 2026-07-25)。
    ///
    /// `boot` は1台分の実起動の差し込み口(既定 nil = 本番経路。テストは失敗するスタブを渡して
    /// 直列性・再試行回数・部分失敗の非致命性だけを検証する)。本番経路は
    /// `DeviceBooter.startEmulator(avd:locale:)` → `waitForAndroidBoot(serial:)` →
    /// `applyLocale(serial:locale:deviceName:log:)` の順(`AndroidGpuRecovery.recoverCpuFallbackDevices`
    /// と同じ並び)。**プロファイルの locale を使う**(`DeviceBooter.bootOne` は `defaultLocale` 固定
    /// なのでここでは使わない)。
    public static func bootMissingDevices(
        devices: [ResolvedDevice], locale: String,
        log: @escaping @Sendable (String) -> Void,
        boot: ((_ avdID: String, _ deviceName: String) async throws -> Void)? = nil
    ) async -> (booted: [String], failed: [(name: String, error: Error)]) {
        guard !devices.isEmpty else { return ([], []) }
        let effectiveBoot: (String, String) async throws -> Void = boot ?? { avdID, deviceName in
            let serial = try await DeviceBooter.startEmulator(avd: avdID, locale: locale)
            try await DeviceBooter.waitForAndroidBoot(serial: serial)
            await DeviceBooter.applyLocale(serial: serial, locale: locale,
                                           deviceName: deviceName, log: log)
        }

        // 台数と所要の見込みを**先に1行ログする**(数分の無音は「止まった」と誤解される。
        // AndroidGpuRecovery が同じ調子で出している)
        log("🔁 Reviving \(devices.count) dead lane(s) before starting the run"
            + " (about a minute per device)")

        var booted: [String] = []
        var failed: [(name: String, error: Error)] = []
        for device in devices {
            // avd 未指定は起動引数を組めない(plan が除外済み。直接呼ばれたときの保険)。
            // **表示名を AVD ID として使わない** —— 別の AVD を起こしうる
            guard let avd = device.spec.avd else { continue }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            var lastError: Error?
            var succeeded = false
            for attempt in 1...maxBootAttempts {
                do {
                    try await effectiveBoot(avdID, device.name)
                    succeeded = true
                    break
                } catch {
                    lastError = error
                    if attempt < maxBootAttempts {
                        log("⚠️ \(device.name): revive attempt \(attempt)/\(maxBootAttempts) failed"
                            + " — \(error.localizedDescription); retrying")
                    }
                }
            }
            if succeeded {
                booted.append(device.name)
                log("✅ \(device.name): revived (\(avdID))")
            } else {
                let error = lastError ?? LaneRecoveryError(
                    message: "\(device.name): no boot attempt ran")
                failed.append((device.name, error))
                log("❌ \(device.name): could not be revived after \(maxBootAttempts) attempt(s)"
                    + " — \(error.localizedDescription)")
            }
        }
        return (booted, failed)
    }
}

public struct LaneRecoveryError: Error, LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}
