// `adb install` の検証(Play Protect)を通さない。
//
// **ユーザー決定: テストツールはアプリを Google へ送らない。確認も取らない。**
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
//
// **同じ端末への2プロセス同時 install は端末単位の flock で直列化する**(並列ワーカー・
// MCP + run 等)。直列化しないと、片方の restore がもう片方の install の途中で発火して
// 検証を再び有効化しうる(Play Protect の照会が再び出て無期限に止まる)。**restore は
// 読んだ値が非ゼロだったときにしか登録しない**(`isAlreadyOff` の早期 return。既に 0 と
// 読めた側は自分の disable/restore を一切持たないので、後から 0 を書き戻して固定する
// 経路は無い)ので、閉じるべき穴は「直列化していないこと」だけ。
// **鍵は端末の serial**(`run`/`adb` 閉包へ `get-serialno` を1回投げて引く —— 閉包が
// 内部でどう serial を持っているか(AndroidDriver.rawAdb は内蔵・AndroidWebViewUpdate は
// 呼び出しごとに明示)を AdbInstallVerifier 側は知らなくてよい)。
// 引けなければ1本の鍵に丸める(別々の端末を同じ鍵に押し込んで無関係に足止めする側の誤りは、
// 逆向き(取り違えて競合を許す)より安全)。
// **flock はブロッキング**(タイムアウト無し) —— 相手は install が終われば必ず手放す
// (プロセスが死んでも OS が自動で外す。RetentionSweepLock と同じ理由)ので待てば必ず開く。
// ロックファイルを開けない/作れない場合は fail open(検証を壊さず動くことを優先する
// 既存方針を踏襲)。

import FTCore
import Foundation

public enum AdbInstallVerifier {

    public static let settingKey = "verifier_verify_adb_installs"

    /// キルスイッチの伝搬経路: 実行プロファイルの `playProtectBypass`(既定 true)→ この環境変数
    /// (`FTCore.RunEnvironment` が唯一の注入元)→ `bypassEnabled`。
    /// **未設定 = バイパスする**(プロファイルを通らない経路 ── `fleetest install`・MCP の直接指定 ── でも
    /// 送らない側に倒す)。"0" / "false" / "off" / "no" だけが OFF
    public static let environmentKey = RunEnvironmentKeys.playProtectBypass

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
    /// (黙って検証を残す側 = 止まるだけで、設定を壊す側には倒さない)。
    /// **キルスイッチ(`bypassEnabled` = false)のときは端末に1バイトも書かず body だけ**
    /// (この経路では端末単位の錠も取らない = get-serialno すら撃たない)。
    /// **同じ端末への呼び出しは錠で直列化する**(`withDeviceLock` の宣言参照)。
    /// `run` は adb 引数列 → (status, output)
    public static func withVerificationOff<T>(run: ([String]) throws -> (status: Int32, output: String),
                                              body: () throws -> T,
                                              environment: [String: String] = ProcessInfo.processInfo.environment
    ) rethrows -> T {
        guard bypassEnabled(environment: environment) else { return try body() }
        return try withDeviceLock(run: run) {
            guard let read = try? run(readArguments), read.status == 0 else { return try body() }
            let original = read.output
            if isAlreadyOff(rawValue: original) { return try body() }
            guard (try? run(disableArguments))?.status == 0 else { return try body() }
            defer { _ = try? run(restoreArguments(original: original)) }
            return try body()
        }
    }

    /// テストだけが使う差し替え口。**production は常に nil**(既定の `~/.fleetest` を使う)。
    /// 実 `~/.fleetest` を触ると並列に走る他のテスト・実運用の錠と衝突するため、
    /// テストは自分専用の一時ディレクトリを指すこと(FMLock の `lockDirectoryForTesting` と同じ規律)
    static var lockDirectoryForTesting: URL?

    static var lockDirectory: URL {
        lockDirectoryForTesting ?? RetentionSweepLock.defaultDirectory
    }

    /// `run`/`adb` 閉包が向いている1台の識別子。**`get-serialno` を1回投げて引く** ——
    /// 閉包が serial をどう内蔵しているか(AndroidDriver.rawAdb は内部で `-s` を足す・
    /// AndroidWebViewUpdate は呼ぶたびに明示で足す)を知らなくても、閉包そのものに
    /// 訊けば向いている端末の実 serial が返る(serial 未指定 = 接続1台だけの adb の意味論も
    /// そのまま乗る)。引けなければ丸めた1本の鍵にする(冒頭コメント参照)
    static func deviceLockKey(run: ([String]) throws -> (status: Int32, output: String)) -> String {
        guard let result = try? run(["get-serialno"]), result.status == 0 else { return "unknown-device" }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown-device" : sanitizedForLockFilename(trimmed)
    }

    /// 端末 serial → ファイル名に安全な形(純粋)。Wi-Fi 接続の serial は `192.168.1.23:5555` の
    /// ように `:` を含むため、パス区切りに化けうる文字は `_` に潰す
    static func sanitizedForLockFilename(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(raw.map { allowed.contains($0) ? $0 : "_" })
    }

    /// 端末単位の直列化。**`flock` はブロッキング**(冒頭コメント参照: 相手は install が
    /// 終われば必ず手放す・プロセス死でも OS が自動で外す)。
    /// ロックファイルを開けない/作れないときは fail open(取れないより動くことを優先)
    private static func withDeviceLock<T>(run: ([String]) throws -> (status: Int32, output: String),
                                          _ body: () throws -> T) rethrows -> T {
        let key = deviceLockKey(run: run)
        let directory = lockDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("adb-install-verifier-\(key).lock")
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        _ = flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
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
