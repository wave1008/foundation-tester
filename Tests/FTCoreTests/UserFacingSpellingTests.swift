// 利用者向けの面(user-docs の日本語・README・拡張の i18n と package.nls.ja.json)の表記ゆれを落とす。
// 規則の本文は CLAUDE.md §用語(利用者向けの表記)。長音の規則は i18n のコメントにも掛かる・「機械」は i18n では `ja:` 文字列だけを見る。
// 寄せる先は件数の多い側(サーバーだけはユーザー決定で長音付き): サーバー・ドライバ・フォルダ・インストーラ・モニター(macOS のアプリ名「アクティビティモニタ」は固有名詞)。
// 機械そのものは「マシン」(用語集の「マシン名」「マシン設定」と揃える。機械的・機械可読・機械向け・機械作業・機械判定は別の語)。
// 「受け手」は保守者の語なので user-docs に書かない(スキルはエージェントが読むので対象外)。
// user-docs/images/ の図を描くスクリプトは描いた画像と食い違うので走査しない(拡張子で外れる)。

import Foundation
import XCTest
import FTCore
import FTTestSupport

final class UserFacingSpellingTests: XCTestCase {

    private struct Rule: Sendable {
        let pattern: String
        let replacement: String
        /// 対象のファイル(リポジトリ相対)
        let applies: @Sendable (String) -> Bool
        /// true = i18n の `ja: "…"` の行だけを見る(コメントは保守者向け)
        let jaStringsOnly: Bool
    }

    private static func isUserDocJa(_ p: String) -> Bool {
        p.hasPrefix("docs/user-docs/") && p.hasSuffix("_ja.md")
    }
    private static func isI18n(_ p: String) -> Bool {
        p.hasPrefix("vscode-fleetest/src/i18n/") && p.hasSuffix(".ts")
    }
    private static func isNlsJa(_ p: String) -> Bool { p == "vscode-fleetest/package.nls.ja.json" }
    private static func isUserFacing(_ p: String) -> Bool {
        isUserDocJa(p) || isI18n(p) || isNlsJa(p) || p == "README.md" || p == "vscode-fleetest/README.md"
    }

    private static let rules: [Rule] = [
        Rule(pattern: "サーバ(?!ー)", replacement: "サーバー", applies: isUserFacing, jaStringsOnly: false),
        Rule(pattern: "ドライバー", replacement: "ドライバ", applies: isUserFacing, jaStringsOnly: false),
        Rule(pattern: "フォルダー", replacement: "フォルダ", applies: isUserFacing, jaStringsOnly: false),
        Rule(pattern: "インストーラー", replacement: "インストーラ", applies: isUserFacing, jaStringsOnly: false),
        Rule(pattern: "(?<!アクティビティ)モニタ(?![ーリ])", replacement: "モニター", applies: isUserFacing, jaStringsOnly: false),
        Rule(pattern: "機械(?!的|可読|向け|作業|判定)", replacement: "マシン", applies: { isUserDocJa($0) || isNlsJa($0) }, jaStringsOnly: false),
        Rule(pattern: "機械(?!的|可読|向け|作業|判定)", replacement: "マシン", applies: isI18n, jaStringsOnly: true),
        Rule(pattern: "受け手", replacement: "あなた / 利用者", applies: isUserDocJa, jaStringsOnly: false),
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func scan() throws -> (hits: [String], scanned: Set<String>) {
        let root = repoRoot
        let compiled = try rules.map { ($0, try NSRegularExpression(pattern: $0.pattern)) }
        var hits: [String] = []
        var scanned: Set<String> = []
        for relative in try GitListedFiles.list(in: root) where isUserFacing(relative) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            else { continue }
            scanned.insert(relative)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                let range = NSRange(line.startIndex..., in: line)
                for (rule, regex) in compiled where rule.applies(relative) {
                    if rule.jaStringsOnly && !line.contains("ja: \"") { continue }
                    if regex.firstMatch(in: line, range: range) != nil {
                        hits.append("\(relative):\(index + 1): 「\(rule.pattern)」→「\(rule.replacement)」: "
                                    + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        return (hits, scanned)
    }

    func testUserFacingSpellingIsUnified() throws {
        XCTAssertEqual(try Self.scan().hits, [], "利用者向けの面の表記を揃える")
    }

    /// 走査が利用者向けの面へ届いていること(対象を外す変更で常に空を返す形を落とす)
    func testScanReachesUserFacingSurfaces() throws {
        let scanned = try Self.scan().scanned
        for path in ["docs/user-docs/overview/glossary_ja.md", "docs/user-docs/quick-start_ja.md",
                     "vscode-fleetest/src/i18n/strings/deviceOps.ts", "vscode-fleetest/package.nls.ja.json", "README.md"] {
            XCTAssertTrue(scanned.contains(path), "走査が届いていない: \(path)")
        }
        XCTAssertGreaterThan(scanned.count, 100, "走査が利用者向けの面に届いていない")
        let monitor = try NSRegularExpression(pattern: Self.rules[4].pattern)
        for (sample, banned) in [("モニタ停止中", true), ("アクティビティモニタ", false), ("モニタリング", false)] {
            let found = monitor.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil
            XCTAssertEqual(found, banned, sample)
        }
    }
}
