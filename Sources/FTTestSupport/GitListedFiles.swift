// リポジトリを走査するテストの一覧の取り方(IOSModeVocabularyTests・UserFacingSpellingTests・FailureWordingVocabularyTests)。
// ディスクを歩かない: gitignore のファイルはクローンごとに中身が違い、そこに当たると**その機械でだけ赤になりコミットでは直せない**。

import Foundation
import FTCore

public enum GitListedFiles {
    /// 追跡分 + 無視されていない未追跡分(足したばかりのファイルも見る)のリポジトリ相対パス。
    /// 追跡中でも作業ツリーで消したファイルは含まれる(読めなければ呼び手が飛ばす)。
    /// git が失敗したら投げる(空の一覧で緑にしない)
    public static func list(in root: URL) throws -> [String] {
        let result = try Shell.run(["/usr/bin/git", "-C", root.path, "ls-files", "-z",
                                    "--cached", "--others", "--exclude-standard"])
        guard let output = result.outputIfSucceeded else {
            throw NSError(domain: "GitListedFiles", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "git ls-files failed: \(result.tail)"])
        }
        return output.split(separator: "\0").map(String.init)
    }
}
