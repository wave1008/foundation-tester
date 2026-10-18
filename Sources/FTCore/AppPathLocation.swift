// アプリプロファイルの appPath / appPathPhysical が一時フォルダを指しているかの判定(ProfileResolver.resolve が警告に使う)。
// 一時フォルダの成果物は OS やエージェントのセッションの片付けで消え、次の run の自動インストールが失敗する
// (クイックスタートの通し検証で、エージェントが iOS アプリを自分の scratchpad = /private/tmp/... にビルドして appPath に書いた)。
// 判定は固定の接頭辞だけ(TMPDIR 等の環境は読まない = テストと本番で同じ答え)。新しい検知なので警告に留める(止めない)
import Foundation

public enum AppPathLocation {
    /// `/tmp`・`/var/folders`(TMPDIR の実体)と、その `/private` 側の名前
    static let temporaryPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

    /// 見るのは絶対パスの宣言だけ(`/` か `~` で始まる)。相対パスはリポジトリ基準 = リポジトリごと一時フォルダに置いたのは
    /// 利用者の選択で、そこへ警告すると毎回出る(テストのひな形も一時フォルダに作る)
    public static func isAbsoluteDeclaration(_ declared: String) -> Bool {
        declared.hasPrefix("/") || declared.hasPrefix("~")
    }

    /// 解決済みの絶対パスが一時フォルダの中か。**カーネルと同じ順で先頭から1要素ずつたどる**: 在る部分はリンクを解き
    /// (`realpath`。/private を落とさない)、`..` は**解いた先の**親へ上がる。先に `..` を畳むとリンクの情報を失う
    /// (`<リンク>/../App.app` はリンク先の親を指す)。まだ無い末尾(ビルド前の .app)はそのまま足す
    public static func isTemporary(_ absolutePath: String) -> Bool {
        let path = resolvingLikeTheKernel(absolutePath)
        return temporaryPrefixes.contains { path.hasPrefix($0) || path + "/" == $0 }
    }

    static func resolvingLikeTheKernel(_ absolutePath: String) -> String {
        var current = "/"
        for component in absolutePath.split(separator: "/").map(String.init) {
            switch component {
            case ".": continue
            case "..": current = (current as NSString).deletingLastPathComponent
            default:
                let candidate = (current as NSString).appendingPathComponent(component)
                if FileManager.default.fileExists(atPath: candidate), let real = realpath(candidate, nil) {
                    current = String(cString: real)
                    free(real)
                } else {
                    current = candidate
                }
            }
        }
        return current
    }

    public static func temporaryWarning(appProfile: String, platform: String, key: String, path: String) -> String {
        "app profile \(appProfile) (\(platform)): \(key) points into a temporary folder (\(path));"
            + " it can be deleted, and the next run then cannot install the app"
            + " — build the app into its own repository (or another lasting folder) and point \(key) there"
    }
}
