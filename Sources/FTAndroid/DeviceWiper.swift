// 実行プロファイルに載っている仮想デバイス1台の Wipe Data(人が右クリックから撃つ手動操作)。
// Android = AndroidDataWiper(Android Studio の Wipe Data と同じファイル集合)、
// iOS = simctl erase(Erase All Content and Settings)。**実機は対象外**(端末を初期化する操作は
// 持たない。webview 側でも項目を出さないが、CLI を直に叩かれても止める)。
// DeviceBooter と同居しているのは、停止・再起動・ブリッジ供給をそのまま使うため(この enum に
// 起動処理の複製を持たない)。

import Foundation
import FTBridgeClient
import FTCore

public enum DeviceWiperError: Error, LocalizedError, Equatable {
    case physicalDevice(name: String)
    case noAVD(name: String)
    case unsupportedPlatform(String)
    case eraseFailed(name: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .physicalDevice(let name):
            return "\(name) is a physical device — Wipe Data is only available for virtual devices"
        case .noAVD(let name):
            return "no avd is specified for \(name) (add \"avd\" to the device in the run profile)"
        case .unsupportedPlatform(let platform):
            return "Wipe Data is not available for platform \(platform)"
        case .eraseFailed(let name, let detail):
            return "\(name): simctl erase failed — \(detail)"
        }
    }
}

public enum DeviceWiper {

    /// どちらの実装へ振るか(I/O を持たない pure な判定。ユニットテスト対象)
    public enum Target: Equatable {
        case ios
        case android(avd: String)
    }

    /// spec/platform から対象を決める。**実機・avd 無しはここで落とす**(消せないものを
    /// 「停止 → 削除」の途中まで進めない)
    public static func target(spec: DeviceSpec, platform: String) throws -> Target {
        guard !spec.isPhysical else { throw DeviceWiperError.physicalDevice(name: spec.name) }
        switch platform {
        case "ios":
            return .ios
        case "android":
            guard let avd = spec.avd else { throw DeviceWiperError.noAVD(name: spec.name) }
            return .android(avd: avd)
        default:
            throw DeviceWiperError.unsupportedPlatform(platform)
        }
    }

    /// 1台を初期化する。**稼働中だったデバイスだけ起こし直す**(止まっていたデバイスを勝手に起動しない)。
    /// status のフェーズ集合は AndroidDataWiper と同じ("stopping"/"rebooting"/"done"/"failed")——
    /// 拡張はどちらの経路でも同じタイル表示を使う。
    /// **消す前に run-lease を確認する**(規律④「他人の run を殺す操作はロックを読む」。Wipe は
    /// 不可逆なので stop より重い)。iOS は `eraseSimulator` → `DeviceBooter.shutdownOne` が
    /// 判定を通るが、Android は削除の本体(`AndroidDataWiper.wipeOne`)に lease 判定が無いので、
    /// ここで呼ぶ前に同じ判定(`DeviceBooter.stopRefusal`)へ通す。拒否は iOS 経路と同じ
    /// `DeviceBooterError.commandFailed` で throw する。
    public static func wipeOne(
        spec: DeviceSpec, platform: String, repoRoot: URL?,
        locale: String = DeviceBooter.defaultLocale,
        force: Bool = false,
        /// テスト注入用。nil なら `(try? RepoRoot.find())?.appendingPathComponent(".fleetest")`
        leaseStateDir: URL? = nil,
        /// テスト注入用(Android の lease 鍵解決)。nil なら `DeviceBooter.leaseKey`
        /// (= 起動中 AVD と照合した adb serial。adb を叩く)を使う
        androidLeaseKey: (() -> String?)? = nil,
        status: (@Sendable (String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        switch try target(spec: spec, platform: platform) {
        case .android(let avd):
            let key = androidLeaseKey?() ?? DeviceBooter.leaseKey(spec: spec, platform: platform)
            if let refusal = DeviceBooter.deviceInUseRefusal(
                deviceName: spec.name, keys: [key].compactMap { $0 }, force: force, offersForce: true,
                leaseStateDir: leaseStateDir) {
                throw DeviceBooterError.commandFailed(refusal)
            }
            // **戻り値で成否を返させない**(`_ =` で捨てると「消えていないのに成功」になる。
            // 実際に起きた)。失敗は throw で上がってくる
            try await AndroidDataWiper.wipeOne(
                deviceName: spec.name, avd: avd, locale: locale, status: status, log: log)
        case .ios:
            try await eraseSimulator(
                spec: spec, repoRoot: repoRoot, locale: locale, force: force,
                leaseStateDir: leaseStateDir, status: status, log: log)
        }
    }

    /// iOS: ブリッジ停止 → simctl shutdown → simctl erase →(稼働中だったデバイスだけ)再ブート+ブリッジ供給。
    /// **erase は shutdown 済みでないと拒否される**ので停止は必須(shutdownOne が停止済みなら no-op)。
    /// 稼働中だったデバイスは、消す前に `AppleLanguages`/`AppleLocale` を読んでおき、
    /// erase 後の再起動で書き戻す(`SimulatorLocalePreservation`)
    private static func eraseSimulator(
        spec: DeviceSpec, repoRoot: URL?, locale: String, force: Bool,
        leaseStateDir: URL?,
        status: (@Sendable (String) -> Void)?,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let sim = try SimulatorCatalog.resolve(spec: spec, in: SimulatorCatalog.devices())
        let wasBooted = sim.booted
        // simctl spawn は稼働中のデバイスにしか効かないので、読めるのは稼働中だったデバイスだけ。
        // 停止中だったデバイスや読み取り自体が失敗したデバイスは `locale` 引数から組み立てる
        let preservedLocale: SimulatorLocalePreservation.Snapshot =
            (wasBooted ? SimulatorLocalePreservation.read(udid: sim.udid) : nil)
            ?? SimulatorLocalePreservation.fallback(locale: locale)
        do {
            log("🧹 \(spec.name): wiping data (1/1) — stopping the simulator...")
            status?("stopping")
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: "ios", repoRoot: repoRoot, force: force,
                leaseStateDir: leaseStateDir, log: log)

            // erase は初回ブートの再構築を伴わない代わりに、コンテナの削除で数十秒かかることがある
            let result = try Shell.run(["xcrun", "simctl", "erase", sim.udid], timeout: 300)
            guard result.status == 0 else {
                throw DeviceWiperError.eraseFailed(name: spec.name, detail: result.tail)
            }

            if wasBooted {
                log("🧹 \(spec.name): data wiped (\(sim.name)). Rebooting...")
                status?("rebooting")
                try await DeviceBooter.bootOne(spec: spec, platform: "ios", log: log)
                // ロケールを書き戻す。`defaults write` はいま走っているプロセスの
                // ユーザーデフォルトを書き換えるだけで、既にこの起動で立ち上がった
                // SpringBoard・権限アラート等のシステム UI には効かない —— それらへ反映させるには
                // 書いた後にもう一度起動し直す必要がある(起動前に書ければ1回で済むが、simctl
                // spawn は稼働中のデバイスにしか使えないため確認できていない。要デバイス確認)
                SimulatorLocalePreservation.write(udid: sim.udid, snapshot: preservedLocale, log: log)
                try await DeviceBooter.shutdownOne(
                    spec: spec, platform: "ios", repoRoot: repoRoot, force: force,
                    leaseStateDir: leaseStateDir, log: log)
                try await DeviceBooter.bootOne(spec: spec, platform: "ios", log: log)
                // 起動と同じ扱いにする(供給しないと画面が取れず「起動済み(ブリッジ未接続)」で止まる。
                // ApiDeviceUp と同じ理由)。repoRoot が無ければ供給できないので飛ばす
                if let repoRoot {
                    _ = try await BridgeProvisioner(repoRoot: repoRoot)
                        .provision(devices: [(spec.name, spec)], log: log)
                }
                log("✅ \(spec.name): Wipe Data finished (1/1)")
            } else {
                log("✅ \(spec.name): Wipe Data finished (1/1, \(sim.name); not running, so no reboot)")
            }
            status?("done")
        } catch {
            status?("failed")
            throw error
        }
    }
}
