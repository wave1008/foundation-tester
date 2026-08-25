// コメントが指す先が実在するかを走査する。コンパイルでは落ちない誤りで、実害を出している:
//   - 存在しない関数を説明する孤児コメント(実装を書かずに説明だけ残った)
//   - 撤去済みのシンボル・移動したファイルを指すポインタ(読者が確かめられない)
//
// 見るのは「機械で正否が決まる2種」だけ。散文の良し悪しは対象外。
//   ルールA: コメント中の `〜Tests` は、実在するテストクラス・ファイル・ターゲット名であること
//   ルールB: コメント中のリポジトリ相対パスは、実在するファイルであること
// どちらもリポジトリ全数で誤検知0を確認してから入れてある。散文語が引っかかったら proseWords へ
// 足す(規則を緩めるより、その語だけ除外するほうが砦が残る)。
//
// 走査は1回だけ行って両テストで共有する(ファイルを2度読むと実行時間が倍になる)。

import Foundation
import XCTest

final class CommentPointerTests: XCTestCase {

    /// クラス名ではない散文。足すのは「その語がコメントの地の文である」と確認したときだけ
    private static let proseWords: Set<String> = ["UITests"]

    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".ftester", "node_modules", "dist", "out-test", "media",
        "Generated", "results", "DerivedData", "build", ".gradle", "Pods",
    ]

    private static let sourceExtensions: Set<String> = ["swift", "ts", "m", "h", "java", "mjs", "js"]

    /// パスとして書かれうる拡張子。**長いものから並べる** —— 交替は左から試されるので
    /// `m` を先に置くと `design.md` が `design.m` として切り出され、全 docs 参照が偽陽性になる
    private static let pathExtensions = "swift|mjs|json|java|yml|xml|md|ts|js|sh|py|m|h"

    // MARK: - 走査(プロセスに1回)

    private struct Repo {
        var comments: [(file: String, line: Int, text: String)] = []
        var paths: Set<String> = []          // 実在するファイル(リポジトリ相対)
        var pathSuffixes: Set<String> = []   // 末尾一致(パッケージ相対の書き方を許す)
        var names: Set<String> = []          // 実在するテスト名・ターゲット名・ディレクトリ名
        var sourceCount = 0
    }

    private static let repo: Repo = scanRepo()

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func scanRepo() -> Repo {
        var repo = Repo()
        let root = repoRoot
        let rootPath = root.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return repo }
        var sources: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) { walker.skipDescendants(); continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { repo.names.insert(name); continue }
            let relative = String(url.path.dropFirst(rootPath.count + 1))
            repo.paths.insert(relative)
            let parts = relative.split(separator: "/").map(String.init)
            for i in parts.indices { repo.pathSuffixes.insert(parts[i...].joined(separator: "/")) }
            if name.hasSuffix(".swift") { repo.names.insert(String(name.dropLast(6))) }
            if name.hasSuffix(".test.mjs") { repo.names.insert(name) }
            if sourceExtensions.contains(url.pathExtension) { sources.append(relative) }
        }
        repo.sourceCount = sources.count
        for relative in sources {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else { continue }
            // テストクラスの宣言(Tests/ と XCUITest ランナー)
            if relative.hasPrefix("Tests/") || relative.hasPrefix("Runner/") {
                repo.names.formUnion(captures("\\bclass\\s+([A-Za-z0-9_]+)\\b", in: text))
            }
            // 行頭がコメント記号の行だけを見る(文字列リテラル中の `//` を拾わない = 誤検知を出さない側)
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
                guard trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") else { continue }
                if trimmed.hasPrefix("*/") { continue }
                repo.comments.append((relative, index + 1, String(raw)))
            }
        }
        if let package = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) {
            repo.names.formUnion(captures("\\.testTarget\\(\\s*name:\\s*\"([^\"]+)\"", in: package))
        }
        repo.names.formUnion(proseWords)
        return repo
    }

    // MARK: - ルールA: `〜Tests` は実在すること

    func testCommentsDoNotPointAtNonexistentTests() {
        let repo = Self.repo
        XCTAssertGreaterThan(repo.sourceCount, 100, "走査対象が少なすぎる(スキップ規則を壊していないか)")
        var broken: [String] = []
        for entry in repo.comments {
            for name in Self.captures("(?<![A-Za-z0-9_])([A-Z][A-Za-z0-9]*Tests)\\b", in: entry.text)
            where !repo.names.contains(name) {
                broken.append("\(entry.file):\(entry.line)  \(name)")
            }
        }
        XCTAssertTrue(broken.isEmpty, """
            実在しないテスト名を指すコメントがある(改名・移動でポインタが外れた)。
            正しい名前へ直すか、散文なら CommentPointerTests.proseWords へ足すこと:
            \(broken.joined(separator: "\n"))
            """)
    }

    // MARK: - ルールB: リポジトリ相対パスは実在すること

    func testCommentsDoNotPointAtNonexistentPaths() {
        let repo = Self.repo
        XCTAssertGreaterThan(repo.comments.count, 1000, "コメントが少なすぎる(走査が壊れていないか)")
        let pattern = "(?<![A-Za-z0-9_/.])((?:Sources|Tests|Runner|InAppBridge|AndroidRunner|Scripts|docs"
            + "|vscode-ftester|Bench)/[A-Za-z0-9_.+\\-/]+\\.(?:\(Self.pathExtensions)))(?![A-Za-z0-9])"
        var broken: [String] = []
        for entry in repo.comments {
            for path in Self.captures(pattern, in: entry.text) {
                // 省略記法(Runner/.../X.swift)はどれか1つを指していないので対象外
                if path.contains("...") || path.contains("…") { continue }
                if repo.paths.contains(path) || repo.pathSuffixes.contains(path) { continue }
                broken.append("\(entry.file):\(entry.line)  \(path)")
            }
        }
        XCTAssertTrue(broken.isEmpty, """
            実在しないファイルを指すコメントがある(移動・改名・削除でポインタが外れた)。
            現在の位置へ直すこと(消えた資産を指しているなら記述ごと落とす):
            \(broken.joined(separator: "\n"))
            """)
    }
}
