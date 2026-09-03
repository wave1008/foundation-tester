// 「陽性/陰性」は**検知**の語彙(発火したかどうか)で、**判定の結果(緑/赤)には使わない**。
// 規則は CLAUDE.md §用語(陽性/陰性)、由来は docs/maintainer-notes.md §11。
// occlusion-guard だけが「発火すると赤になる検知」なので、同じ事象を検知として語るか判定として
// 語るかで極性が反転し、禁止した一語がリポジトリの両側に跨っていた。コンパイルでは落ちない誤りで、
// 読み手(次に触る Claude Code)が現象を取り違えるので走査で落とす。
//
// **例外は1つだけ**: 実行プロファイルの鍵 `falsePositiveCheck` のラベル。受け手の JSON の鍵なので
// 改名しない。**ラベルを名乗れるファイルの集合まで等号で固定する** —— 例外が散らばると、鍵の名前
// ではなく現象の説明として使われはじめ、規則が実質無くなる。
//
// **走査の対象外**(3つとも理由が別):
//   - CLAUDE.md / docs/maintainer-notes.md: 禁止語を書けないと規則そのものが書けない(人間の規律で守る)
//   - TestProjects/: ユーザー資産(CLAUDE.md「並列一括作業」)
//   - reports/: .gitignore 済み(run の生成レポートと Apple へ提出済みの資料)。**提出物を遡って書き換えない**

import Foundation
import XCTest

final class VocabularyPolarityTests: XCTestCase {

    /// 判定・検知のどちら側とも読める語。**代わりに使う語は CLAUDE.md の表**(真陽性・誤検知・
    /// 見逃し・誤った緑・誤った赤・誤反転)
    private static let bannedWords = ["偽陽性", "偽陰性"]

    /// `falsePositiveCheck` のラベルとして通ってよい綴り。**この綴りで始まる出現だけ**を除いてから
    /// 禁止語を探す(`偽陽性` 単独は残る)
    private static let allowedLabels = ["偽陽性検証", "偽陽性チェック"]

    /// ラベルを書いてよいファイル(リポジトリ相対)。**増やすときは「鍵の名前を指しているか」を
    /// 確かめてから** —— 現象の説明なら誤った緑 / 誤検知に書き換えるのが正しい
    private static let labelFiles: Set<String> = [
        "README.md",
        "Sources/FTCore/RunProfile.swift",
        "Tests/FTCoreTests/ProfileResolverTests.swift",
        "docs/ci.md",
        "docs/commands.md",
        "docs/design.md",
        "docs/performance-tuning.md",
        "docs/user-docs/in_action/ci_ja.md",
        "docs/user-docs/overview/environments_ja.md",
        "docs/user-docs/project/run_profile_ja.md",
        "docs/user-docs/testclass/select_and_assert_ja.md",
        "docs/verification.md",
        "vscode-fleetest/src/i18n/strings/panels.ts",
        "vscode-fleetest/src/i18n/strings/webviewMonitorB.ts",
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".fleetest", "node_modules", "dist", "out-test", "media",
        "Generated", "results", "DerivedData", "build", ".gradle", "Pods",
    ]

    private static let scannedExtensions: Set<String> = ["swift", "md", "ts", "mjs", "js", "sh"]

    /// 対象外(前方一致)。この走査テスト自身は禁止語を持つので `#filePath` で除く
    private static let exemptPrefixes = [
        "CLAUDE.md", "docs/maintainer-notes.md", "TestProjects/", "reports/",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let ownRelativePath: String = {
        let root = repoRoot.path
        return String(#filePath.dropFirst(root.count + 1))
    }()

    private struct Hit {
        let file: String
        let line: Int
        let text: String
        let isLabel: Bool
    }

    /// プロセスに1回だけ走査する(2つのテストで共有)
    private static let hits: [Hit] = scan()

    private static func scan() -> [Hit] {
        let root = repoRoot
        let rootPath = root.path
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Hit] = []
        for case let url as URL in walker {
            if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard scannedExtensions.contains(url.pathExtension) else { continue }
            let relative = String(url.path.dropFirst(rootPath.count + 1))
            if relative == ownRelativePath { continue }
            if exemptPrefixes.contains(where: { relative.hasPrefix($0) }) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard bannedWords.contains(where: { text.contains($0) }) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var stripped = String(line)
                var sawLabel = false
                for label in allowedLabels where stripped.contains(label) {
                    sawLabel = true
                    stripped = stripped.replacingOccurrences(of: label, with: "")
                }
                let bare = bannedWords.contains { stripped.contains($0) }
                guard bare || sawLabel else { continue }
                found.append(Hit(file: relative, line: index + 1,
                                 text: String(line).trimmingCharacters(in: .whitespaces),
                                 isLabel: sawLabel && !bare))
            }
        }
        return found
    }

    func testBannedPolarityWordsAreGone() {
        let violations = Self.hits.filter { !$0.isLabel }
        XCTAssertTrue(violations.isEmpty, """
            「陽性/陰性」は検知の語彙で、判定(緑/赤)には使わない(CLAUDE.md §用語・maintainer-notes §11)。
            検知が誤って発火 = 誤検知 / 発火しなかった = 見逃し(原理的限界は取りこぼし) /
            判定が誤って通った = 誤った緑 / 誤って落ちた = 誤った赤 / ガードの誤反転 = 誤反転。
            \(violations.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }

    /// 例外(`falsePositiveCheck` のラベル)が散らばっていないか。**等号で固定する**
    func testLabelExceptionStaysPinned() {
        let actual = Set(Self.hits.filter(\.isLabel).map(\.file))
        XCTAssertEqual(actual, Self.labelFiles, """
            `falsePositiveCheck` のラベルを書いているファイルが変わった。
            増えたファイルは「鍵の名前を指しているか」を確かめること(現象の説明なら誤った緑 / 誤検知)。
            追加: \(actual.subtracting(Self.labelFiles).sorted())
            消えた: \(Self.labelFiles.subtracting(actual).sorted())
            """)
    }
}
