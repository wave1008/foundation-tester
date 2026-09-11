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

    /// 撃ち直しても同じ結果になると分かっている FATAL(システムイメージの実体が無い等)。
    /// **実在した文言だけを載せる**(推測で広げない。決定的でない失敗まで1回で諦めさせると、
    /// 一過性の起動不良を早々に見捨ててしまう)。 M1Ultra の4台で観測した唯一の実例
    /// —— `system-images/android-35/google_apis/arm64-v8a/` ディレクトリが丸ごと消えており、
    /// 3回×4台のブート再試行が全て同じ `FATAL | Broken AVD system path` で終わった
    static let decisiveFatalMarkers = ["Broken AVD system path"]

    /// `boot` のエラーが `decisiveFatalMarkers` のいずれかを含むか(純粋関数)
    static func isDecisiveFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return decisiveFatalMarkers.contains { message.contains($0) }
    }

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
        for (offset, device) in devices.enumerated() {
            // 進行は**1台ごとに開始も出す**(直列なので完了行だけだと、1台に1分近くかかる間
            // 何も出ない。読み手は拡張の「テスト実行」タブ = ApiRunCommand.logSupply)
            let progress = "(\(offset + 1)/\(devices.count))"
            // avd 未指定は起動引数を組めない(plan が除外済み。直接呼ばれたときの保険)。
            // **表示名を AVD ID として使わない** —— 別の AVD を起こしうる
            guard let avd = device.spec.avd else { continue }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            log("▶️ \(progress) \(device.name): starting")
            var lastError: Error?
            var succeeded = false
            var decisive = false
            var attemptsRun = 0
            for attempt in 1...maxBootAttempts {
                attemptsRun = attempt
                do {
                    try await effectiveBoot(avdID, device.name)
                    succeeded = true
                    break
                } catch {
                    lastError = error
                    // 撃ち直しても同じ結果になると分かっている FATAL は3回払わない
                    // (例: システムイメージの実体が無い個体を3回×N台リトライして
                    // run 開始を数分遅らせた 実害)
                    if isDecisiveFailure(error) {
                        decisive = true
                        break
                    }
                    if attempt < maxBootAttempts {
                        log("⚠️ \(device.name): revive attempt \(attempt)/\(maxBootAttempts) failed"
                            + " — \(error.localizedDescription); retrying")
                    }
                }
            }
            if succeeded {
                booted.append(device.name)
                // 前回のこの AVD の復活失敗の記録は用済み(消さないと、次に成功した後の
                // 無関係な失敗が古い理由を引き継ぐ)
                RevivalOutcomeLedger.shared.clearFailure(avdID: avdID)
                log("✅ \(progress) \(device.name): revived (\(avdID))")
            } else {
                let error = lastError ?? LaneRecoveryError(
                    message: "\(device.name): no boot attempt ran")
                failed.append((device.name, error))
                // この AVD の解決がこの後 avdNotRunning で失敗したとき、
                // 「devices up で起動しろ」ではなく復活失敗の実際の理由を言えるようにする
                // (呼び出し側 ProfileRunner/ApiRunCommand を経由させず FTAndroid 内で完結させる)
                RevivalOutcomeLedger.shared.recordFailure(
                    avdID: avdID, reason: error.localizedDescription)
                log("❌ \(progress) \(device.name): could not be revived after \(attemptsRun) attempt(s)"
                    + " — \(error.localizedDescription)"
                    + (decisive ? " (not retrying — this failure won't resolve on its own)" : ""))
            }
        }
        return (booted, failed)
    }
}

/// 復活の失敗理由を、後続の解決失敗(`AndroidDeviceCatalog` の `avdNotRunning`)へ渡すための
/// プロセス内の受け渡し。**呼び出し側(ProfileRunner/ApiRunCommand)を経由させない** ——
/// 復活と解決は同じプロセス内で必ず「先に bootMissingDevices・後で resolveSerial」の順に呼ばれるので、
/// グローバルな受け渡しで足りる。key は `AndroidDeviceCatalog.canonicalAVDID` 後の avd ID
/// (bootMissingDevices と resolveSerial の両方がこの正規化形を使う)
final class RevivalOutcomeLedger: @unchecked Sendable {
    static let shared = RevivalOutcomeLedger()

    private let lock = NSLock()
    private var failures: [String: String] = [:]

    func recordFailure(avdID: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        failures[avdID] = reason
    }

    func clearFailure(avdID: String) {
        lock.lock(); defer { lock.unlock() }
        failures.removeValue(forKey: avdID)
    }

    func failureReason(avdID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[avdID]
    }
}

public struct LaneRecoveryError: Error, LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}
