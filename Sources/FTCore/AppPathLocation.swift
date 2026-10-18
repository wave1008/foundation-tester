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

    /// 解決済みの絶対パスが一時フォルダの中か。**`.` / `..` を畳み、シンボリックリンクを解いてから**見る
    /// (接頭辞だけだと `/private/./tmp/…` や一時フォルダへのリンクを見逃し、`/private/tmp/../../Users/…` を誤って警告する)。
    /// リンクの解決は在るところまで(無いパスは畳んだ形のまま判定する)
    public static func isTemporary(_ absolutePath: String) -> Bool {
        // resolvingSymlinksInPath は先頭の /private を落とす(/private/tmp → /tmp)ので、接頭辞は両方の名前で持つ
        let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.resolvingSymlinksInPath().path
        return temporaryPrefixes.contains { path.hasPrefix($0) || path + "/" == $0 }
    }

    public static func temporaryWarning(appProfile: String, platform: String, key: String, path: String) -> String {
        "app profile \(appProfile) (\(platform)): \(key) points into a temporary folder (\(path));"
            + " it can be deleted, and the next run then cannot install the app"
            + " — build the app into its own repository (or another lasting folder) and point \(key) there"
    }
}
