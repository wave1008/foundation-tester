// TemporaryDirectory.swift
// 一時ファイルの置き場。**シナリオ実行バイナリ(子)に入るコードは `NSTemporaryDirectory()` /
// `FileManager.temporaryDirectory` を直接使わずこれを使う**(`TemporaryDirectoryScanTests`)。
// 両者は `TMPDIR` を見ず常にユーザーの一時領域 `/var/folders/xx/yy/T/` を返す(実測)が、サンドボックスの
// 子が書けるのは親が `TMPDIR` で渡す子専用の一時フォルダだけ(`ScenarioSandbox.childTemporaryDirectory`)。
import Foundation

public enum TemporaryDirectory {
    /// `TMPDIR` が絶対パスならそこ、無ければ `NSTemporaryDirectory()`
    public static var url: URL {
        url(environment: ProcessInfo.processInfo.environment)
    }

    static func url(environment: [String: String]) -> URL {
        if let dir = environment["TMPDIR"], dir.hasPrefix("/") {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}
