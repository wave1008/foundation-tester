// マシンプロファイルに載っている仮想デバイス1台の Wipe Data(人が右クリックから撃つ手動操作)。
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
            return "no avd is specified for \(name) (add \"avd\" to the machine profile)"
        case .unsupportedPlatform(let platform):
            return "Wipe Data is not available for platform \(platform)"
        case .eraseFailed(let name, let detail):
            return "\(name): simctl erase failed — \(detail)"
        }
    }
}

/// iOS の Wipe Data(`simctl erase`)は `AppleLanguages`/`AppleLocale` も
/// 巻き添えにして消し、ホスト Mac の既定へ戻してしまう(実測: ja-JP → erase → ("en-US","ja-JP"))。
/// Android は `AndroidDataWiper` が `-change-locale` で戻しているのに、iOS だけ書き戻す経路が
/// 無かった。**読み書きとも `simctl spawn`(公式インタフェース)を使う** —— これは稼働中の台にしか
/// 効かないので、**稼働中だった台だけ元へ戻す**(`AndroidDataWiper` と同じ「稼働中だった台だけ
/// 起こし直す」規律。停止中だった台はこの後も再起動しないので、書き戻す機会自体が無い)。
/// コマンド列の組み立てと出力の解析だけを純粋関数にして `DeviceWiperTests` で固定する
/// (実際に simctl を叩く部分はデバイスが要るのでテストしない)
enum SimulatorLocalePreservation {
    struct Snapshot: Equatable {
        let languages: [String]
        let locale: String
    }

    /// `defaults read -g AppleLanguages` の OpenStep 配列出力
    /// ("(\n    \"ja-JP\",\n    \"en-US\"\n)")から要素を取り出す
    static func parseLanguages(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line != "(", line != ")" else { return nil }
            if line.hasSuffix(",") { line.removeLast() }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return line.isEmpty ? nil : line
        }
    }

    /// `defaults read -g AppleLocale` の出力(識別子1行。空/未設定は nil)
    static func parseLocale(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 読めなかったとき(停止中だった台/未設定)の組み立て。**引数の `locale`("ja_JP" 形)から作る**
    /// (AppleLanguages はハイフン形を先頭に、英語をフォールバックとして添える —— 言語だけ変えて
    /// 英語の文言が一切出せなくなる事態を避ける)
    static func fallback(locale: String) -> Snapshot {
        Snapshot(languages: [locale.replacingOccurrences(of: "_", with: "-"), "en-US"], locale: locale)
    }

    static func readLanguagesCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "defaults", "read", "-g", "AppleLanguages"]
    }

    static func readLocaleCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "defaults", "read", "-g", "AppleLocale"]
    }

    /// `-g` の下で AppleLanguages と AppleLocale をそれぞれ書く(`defaults write` は1呼び出し
    /// 1キーなので2本に分ける)
    static func writeCommands(udid: String, snapshot: Snapshot) -> [[String]] {
        [["xcrun", "simctl", "spawn", udid, "defaults", "write", "-g",
          "AppleLanguages", "-array"] + snapshot.languages,
         ["xcrun", "simctl", "spawn", udid, "defaults", "write", "-g",
          "AppleLocale", "-string", snapshot.locale]]
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

    /// 1台を初期化する。**稼働中だった台だけ起こし直す**(止まっていた台を勝手に起動しない)。
    /// status のフェーズ集合は AndroidDataWiper と同じ("stopping"/"rebooting"/"done"/"failed")——
    /// 拡張はどちらの経路でも同じタイル表示を使う。
    public static func wipeOne(
        spec: DeviceSpec, platform: String, repoRoot: URL?,
        locale: String = DeviceBooter.defaultLocale,
        status: (@Sendable (String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        switch try target(spec: spec, platform: platform) {
        case .android(let avd):
            // **戻り値で成否を返させない**(`_ =` で捨てると「消えていないのに成功」になる。
            // 2026-08-29 に実際に起きた)。失敗は throw で上がってくる
            try await AndroidDataWiper.wipeOne(
                deviceName: spec.name, avd: avd, locale: locale, status: status, log: log)
        case .ios:
            try await eraseSimulator(
                spec: spec, repoRoot: repoRoot, locale: locale, status: status, log: log)
        }
    }

    /// iOS: ブリッジ停止 → simctl shutdown → simctl erase →(稼働中だった台だけ)再ブート+ブリッジ供給。
    /// **erase は shutdown 済みでないと拒否される**ので停止は必須(shutdownOne が停止済みなら no-op)。
    /// 稼働中だった台は、消す前に `AppleLanguages`/`AppleLocale` を読んでおき、
    /// erase 後の再起動で書き戻す(`SimulatorLocalePreservation`)
    private static func eraseSimulator(
        spec: DeviceSpec, repoRoot: URL?, locale: String, status: (@Sendable (String) -> Void)?,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let sim = try SimulatorCatalog.resolve(spec: spec, in: SimulatorCatalog.devices())
        let wasBooted = sim.booted
        // simctl spawn は稼働中の台にしか効かないので、読めるのは稼働中だった台だけ。
        // 停止中だった台や読み取り自体が失敗した台は `locale` 引数から組み立てる
        let preservedLocale: SimulatorLocalePreservation.Snapshot =
            (wasBooted ? readSimulatorLocale(udid: sim.udid) : nil)
            ?? SimulatorLocalePreservation.fallback(locale: locale)
        do {
            log("🧹 \(spec.name): wiping data (1/1) — stopping the simulator...")
            status?("stopping")
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: "ios", repoRoot: repoRoot, log: log)

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
                // spawn は稼働中の台にしか使えないため確認できていない。要デバイス確認)
                writeSimulatorLocale(udid: sim.udid, snapshot: preservedLocale, log: log)
                try await DeviceBooter.shutdownOne(
                    spec: spec, platform: "ios", repoRoot: repoRoot, log: log)
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

    /// simctl spawn で現在のロケールを読む(稼働中の台にしか効かない)。片方でも読めなければ nil
    /// (部分的な値で上書きするより、丸ごと `locale` 引数からの組み立てへ倒す)
    private static func readSimulatorLocale(udid: String) -> SimulatorLocalePreservation.Snapshot? {
        guard let languagesResult = try? Shell.run(
                SimulatorLocalePreservation.readLanguagesCommand(udid: udid), timeout: 15),
              languagesResult.status == 0,
              let localeResult = try? Shell.run(
                SimulatorLocalePreservation.readLocaleCommand(udid: udid), timeout: 15),
              localeResult.status == 0
        else { return nil }
        let languages = SimulatorLocalePreservation.parseLanguages(languagesResult.output)
        guard !languages.isEmpty,
              let locale = SimulatorLocalePreservation.parseLocale(localeResult.output) else {
            return nil
        }
        return SimulatorLocalePreservation.Snapshot(languages: languages, locale: locale)
    }

    /// ベストエフォート —— 書き戻しに失敗しても Wipe Data 自体は成功として扱う
    /// (ロケールが直らないだけで、消す・作り直すという本来の目的は達成している)
    private static func writeSimulatorLocale(
        udid: String, snapshot: SimulatorLocalePreservation.Snapshot,
        log: @escaping @Sendable (String) -> Void
    ) {
        for command in SimulatorLocalePreservation.writeCommands(udid: udid, snapshot: snapshot) {
            guard let result = try? Shell.run(command, timeout: 15), result.status == 0 else {
                log("⚠️ could not restore the simulator's locale (\(snapshot.locale)) after Wipe Data")
                return
            }
        }
    }
}
