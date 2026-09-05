// `adb install` の検証(Play Protect)を通さない。
//
// **ユーザー決定(2026-09-05): テストツールはアプリを Google へ送らない。確認も取らない。**
// 実測(Pixel 4a・Android 13): release 署名の APK を `adb install -r` すると Play Protect が
// 「Send app for a security check?」(`com.android.vending/…PlayProtectDialogsActivity`)を出して
// install が**無期限に止まる**(9.5 分待っても終わらず、ログは 0 バイト)。同じ APK でも
// 毎回出る(「Don't send」は記憶されない)。`verifier_verify_adb_installs`(開発者オプションの
// 「USB 経由でアプリを確認」)を 0 にすると 4 秒で入り、戻すと再び止まった。Google Play 入りの
// エミュレータも Play Protect を持つ(手元の像は最初から 0 だった)。
// ダイアログを押す方式は採らない —— ボタンはロケール依存のラベルしか持たず(id 無し)、
// 押す前の一瞬でも送信の選択肢が画面に在る。
//
// **門は adb を実行する層(`AndroidDriver.adb`)に在る** —— install 系の引数を見て自動で掛かるので、
// アプリを入れる新しい経路が「門を呼び忘れる」ことは起きない(規律ではなく構造)。
// 例外は bundletool(adb を自分で spawn する)と `AndroidWebViewUpdate`(adb 閉包を外から
// 受ける)で、そこだけ `withVerificationOff` を明示する。素の `Shell.run` で adb install を
// 打つコードは `AdbInstallVerifierTests` のソース走査が落とす。
//
// **設定は install の間だけ切り、元の値へ戻す**(端末の設定を書き換えたまま残さない =
// 71bae1ba と同じ規律)。途中で殺されて 0 が残る側は「送らない」なので安全側。

import FTCore
import Foundation

public enum AdbInstallVerifier {

    public static let settingKey = "verifier_verify_adb_installs"

    /// キルスイッチの伝搬経路: 実行プロファイルの `playProtectBypass`(既定 true)→ この環境変数
    /// (ProfileRunner / ApiRunCommand / MCP の profile 解決が setenv)→ `bypassEnabled`。
    /// **未設定 = バイパスする**(プロファイルを通らない経路 ── `fleetest install`・MCP の直接指定 ── でも
    /// 送らない側に倒す)。"0" / "false" / "off" / "no" だけが OFF
    public static let environmentKey = "FT_PLAY_PROTECT_BYPASS"

    public static func bypassEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment[environmentKey]?.lowercased() {
        case "0", "false", "off", "no": return false
        default: return true
        }
    }

    /// adb の後ろに続く引数列(純粋。adb 実行は呼び出し側)
    public static let readArguments: [String] = ["shell", "settings", "get", "global", settingKey]
    public static let disableArguments: [String] = ["shell", "settings", "put", "global", settingKey, "0"]

    /// 元の値へ戻す引数列。未設定("null"・空)は `delete`(put で "null" を書くと文字列 null が
    /// 入り、既定の「検証する」に戻らない)
    public static func restoreArguments(original rawValue: String?) -> [String] {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return ["shell", "settings", "delete", "global", settingKey]
        }
        return ["shell", "settings", "put", "global", settingKey, trimmed]
    }

    /// 既に 0 なら触らない(戻す必要も無い)
    public static func isAlreadyOff(rawValue: String?) -> Bool {
        (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    /// **アプリを入れる adb コマンドか**(純粋)。先頭の `-s <serial>` は読み飛ばす。
    /// `install` / `install-multiple` / `install-multi-package` と、shell 経由の `pm install` /
    /// `cmd package install`(どれも PackageManager の verifier を通り、同じ照会が出る)
    public static func isInstallCommand(_ args: [String]) -> Bool {
        var rest = args[...]
        if rest.first == "-s", rest.count >= 2 { rest = rest.dropFirst(2) }
        guard let first = rest.first else { return false }
        if ["install", "install-multiple", "install-multi-package"].contains(first) { return true }
        guard first == "shell" else { return false }
        let shell = Array(rest.dropFirst())
        if shell.count >= 2, shell[0] == "pm", shell[1] == "install" { return true }
        if shell.count >= 3, shell[0] == "cmd", shell[1] == "package", shell[2] == "install" { return true }
        return false
    }

    /// 検証を切って `body` を実行し、必ず元へ戻す。読めなければ(adb 失敗)切らずにそのまま実行
    /// (黙って検証を残す側 = 止まるのは従来どおりで、設定を壊す側には倒さない)。
    /// **キルスイッチ(`bypassEnabled` = false)のときは端末に1バイトも書かず body だけ**。
    /// `run` は adb 引数列 → (status, output)
    public static func withVerificationOff<T>(run: ([String]) throws -> (status: Int32, output: String),
                                              body: () throws -> T,
                                              environment: [String: String] = ProcessInfo.processInfo.environment
    ) rethrows -> T {
        guard bypassEnabled(environment: environment) else { return try body() }
        guard let read = try? run(readArguments), read.status == 0 else { return try body() }
        let original = read.output
        if isAlreadyOff(rawValue: original) { return try body() }
        guard (try? run(disableArguments))?.status == 0 else { return try body() }
        defer { _ = try? run(restoreArguments(original: original)) }
        return try body()
    }

    public static func withVerificationOff<T>(adb: ([String]) throws -> Shell.Result,
                                              body: () throws -> T) rethrows -> T {
        try withVerificationOff(run: { args in
            let result = try adb(args)
            return (result.status, result.output)
        }, body: body)
    }
}
