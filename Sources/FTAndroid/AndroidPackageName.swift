// adb shell へ埋めるパッケージ名の検査の入口(文法の定義元は FTCore の AndroidPackageNameGrammar)。`adb shell` はクライアント側の引数を空白で
// 結合して端末側の sh に解釈し直させるので、呼び手(MCP の bundleId・DSL・ライブ操作)から来た名前を
// そのまま並べると `x;reboot` が端末上の別コマンドになる。埋める前に必ずここを通す
// (`AndroidPackageNameTests.testShellSitesEmbeddingPackageNamesAreGuarded` がソース走査で漏れを落とす)。

import FTCore

public enum AndroidPackageName {

    /// 先頭が英字・残りが英数字 / `_` / `.` だけ(Android の applicationId が取りうる文字の集合。
    /// `-` もシェルの特殊文字も含まない)。文法(区切りごとに英字始まり等)までは見ない ——
    /// 目的は端末側の sh に解釈させないことで、存在しない名前は pm / am 自身が断る
    public static func isShellSafe(_ name: String) -> Bool {
        AndroidPackageNameGrammar.isShellSafe(name)
    }

    /// 呼び手の誤り(400)として断る。黙って握りつぶすと「起動した」「消した」と誤った緑になる
    public static func require(_ name: String) throws {
        guard isShellSafe(name) else {
            throw DriverError.badResponse(status: 400,
                body: "not a valid Android package name: \(name.debugDescription)"
                    + " (letters, digits, '_' and '.' only, starting with a letter)")
        }
    }
}
