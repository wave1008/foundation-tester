// 回復の最後の手としてのシミュレータの初期化(`simctl erase`)と、ロケールの保存・書き戻し。
// 手動の Wipe Data(FTAndroid.DeviceWiper)と供給時の回復(BridgeProvisioner)が同じ実装を通る
// (FTAndroid → FTBridgeClient の依存方向のため、共有部品はこちらに置く。DeviceWiper は spec 経由の
// lease 判定つき shutdown/boot を使うので手順の外側は別)。

import FTCore
import Foundation

/// `simctl erase` は `AppleLanguages`/`AppleLocale` も消し、ホスト Mac の既定へ戻す
/// (実測: ja-JP → erase → ("en-US","ja-JP"))。**読み書きとも `simctl spawn`** を使うので稼働中のデバイスにしか効かない。
/// コマンド列の組み立てと出力の解析だけが純粋関数(`DeviceWiperTests` が固定)
public enum SimulatorLocalePreservation {
    public struct Snapshot: Equatable, Sendable {
        public let languages: [String]
        public let locale: String
        public init(languages: [String], locale: String) {
            self.languages = languages
            self.locale = locale
        }
    }

    /// `defaults read -g AppleLanguages` の OpenStep 配列出力
    /// ("(\n    \"ja-JP\",\n    \"en-US\"\n)")から要素を取り出す
    public static func parseLanguages(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line != "(", line != ")" else { return nil }
            if line.hasSuffix(",") { line.removeLast() }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return line.isEmpty ? nil : line
        }
    }

    /// `defaults read -g AppleLocale` の出力(識別子1行。空/未設定は nil)
    public static func parseLocale(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 読めなかったとき(停止中だったデバイス/未設定)の組み立て。**引数の `locale`("ja_JP" 形)から作る**
    /// (AppleLanguages はハイフン形を先頭に、英語をフォールバックとして添える —— 言語だけ変えて
    /// 英語の文言が一切出せなくなる事態を避ける)
    public static func fallback(locale: String) -> Snapshot {
        Snapshot(languages: [locale.replacingOccurrences(of: "_", with: "-"), "en-US"], locale: locale)
    }

    public static func readLanguagesCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "defaults", "read", "-g", "AppleLanguages"]
    }

    public static func readLocaleCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "defaults", "read", "-g", "AppleLocale"]
    }

    /// `-g` の下で AppleLanguages と AppleLocale をそれぞれ書く(`defaults write` は1呼び出し
    /// 1キーなので2本に分ける)
    public static func writeCommands(udid: String, snapshot: Snapshot) -> [[String]] {
        [["xcrun", "simctl", "spawn", udid, "defaults", "write", "-g",
          "AppleLanguages", "-array"] + snapshot.languages,
         ["xcrun", "simctl", "spawn", udid, "defaults", "write", "-g",
          "AppleLocale", "-string", snapshot.locale]]
    }

    /// 現在のロケールを読む(稼働中のデバイスにしか効かない)。片方でも読めなければ nil
    /// (部分的な値で上書きするより、丸ごと呼び手の既定へ倒す)
    public static func read(udid: String) -> Snapshot? {
        guard let languagesResult = try? Shell.run(readLanguagesCommand(udid: udid), timeout: 15),
              languagesResult.status == 0,
              let localeResult = try? Shell.run(readLocaleCommand(udid: udid), timeout: 15),
              localeResult.status == 0
        else { return nil }
        let languages = parseLanguages(languagesResult.output)
        guard !languages.isEmpty, let locale = parseLocale(localeResult.output) else { return nil }
        return Snapshot(languages: languages, locale: locale)
    }

    /// ベストエフォート —— 書き戻しに失敗しても初期化自体は成功として扱う
    /// (ロケールが直らないだけで、消すという本来の目的は達成している)
    public static func write(udid: String, snapshot: Snapshot, log: @escaping @Sendable (String) -> Void) {
        for command in writeCommands(udid: udid, snapshot: snapshot) {
            guard let result = try? Shell.run(command, timeout: 15), result.status == 0 else {
                log("⚠️ could not restore the simulator's locale (\(snapshot.locale)) after erasing it")
                return
            }
        }
    }
}

public enum SimulatorEraseForRecovery {
    /// simctl erase の時限(秒)。コンテナの削除で数十秒かかりうる(DeviceWiper と同じ値)
    static let eraseTimeoutSeconds: TimeInterval = 300

    /// 稼働中のシミュレータを shutdown → erase → boot し、**読めたロケールだけ**書き戻す。
    /// 書いたあとにもう一度 shutdown → boot する(`defaults write` は走っているプロセスにしか効かず、
    /// 既に立ち上がった SpringBoard・権限アラートには次の起動まで反映されない = DeviceWiper と同じ)。
    /// 読めなかったときは書かない(推測のロケールで上書きしない。呼び手の run が後段でロケールを整える)。
    /// 終了コードを見る(`Shell.run` は非ゼロで投げない)。起動は必ず `SimulatorBoot.ensureBooted` を通す
    public static func erase(udid: String, name: String,
                             log: @escaping @Sendable (String) -> Void) async throws {
        let wasBooted = SimulatorCatalog.shutdownObservation(udid: udid) != .stopped
        let preserved = wasBooted ? SimulatorLocalePreservation.read(udid: udid) : nil
        try await shutdownIfRunning(udid: udid, name: name)
        let result = try Shell.run(["xcrun", "simctl", "erase", udid], timeout: eraseTimeoutSeconds)
        guard result.status == 0 else {
            throw BridgeProvisionerError.simulatorEraseFailed(name: name, detail: result.tail)
        }
        try boot(udid: udid, name: name, log: log)
        guard let preserved else {
            log("⚠️ \(name): the simulator's locale could not be read before erasing it, so it was not restored")
            return
        }
        SimulatorLocalePreservation.write(udid: udid, snapshot: preserved, log: log)
        try await shutdownIfRunning(udid: udid, name: name)
        try boot(udid: udid, name: name, log: log)
    }

    private static func shutdownIfRunning(udid: String, name: String) async throws {
        guard SimulatorCatalog.shutdownObservation(udid: udid) != .stopped else { return }
        let outcome = await SimulatorShutdownRetry.shutdown(udid: udid)
        guard outcome.observation == .stopped else {
            throw BridgeProvisionerError.simulatorEraseFailed(
                name: name, detail: "the simulator did not stop after \(SimulatorShutdownRetry.attempts) attempts")
        }
    }

    private static func boot(udid: String, name: String, log: @escaping @Sendable (String) -> Void) throws {
        do {
            try SimulatorBoot.ensureBooted(udid: udid, log: log)
        } catch SimulatorBoot.Error.failed(_, let detail) {
            throw BridgeProvisionerError.simulatorEraseFailed(name: name, detail: detail)
        }
    }
}
