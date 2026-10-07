// AI がシナリオを生成するとき、入力は `type(selector, text)` を優先させる(ユーザー決定)。
// 前に `tap(selector)` / `select(selector)` を置く形はステップが1つ増えるだけ(実測: tap は 0.2〜1 秒)。
// AI が読む見本(スキルの雛形・エージェント向け手引き・索引の説明文)が冗長な形へ戻るのを落とす。
// 冗長な形そのものは DSL として正しい(tap(入力欄) → type("文字列") は支えるべき伝統形)ので、縛るのは見本だけ。

import XCTest
import FTCore

final class TypeAuthoringPreferenceTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `tap("…")` の直後(`;` か改行)に `type(` が来る形と、`tap(…)` / `select(…)` に `.type(` を繋ぐ形
    static func redundantTypeForms(in text: String) -> [String] {
        let patterns = [#"tap\("[^"\n]*"\)\s*(;|\n)\s*type\("#,
                        #"(tap|select)\("[^"\n]*"\)\.type\("#]
        return patterns.flatMap { pattern -> [String] in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
    }

    func testDetectorCatchesTheRedundantForms() {
        XCTAssertEqual(Self.redundantTypeForms(in: "tap(\"#a\"); type(\"x\")").count, 1)
        XCTAssertEqual(Self.redundantTypeForms(in: "tap(\"#a\")\n    type(\"#a\", \"x\")").count, 1)
        XCTAssertEqual(Self.redundantTypeForms(in: "select(\"#a\").type(\"x\")").count, 1)
        XCTAssertEqual(Self.redundantTypeForms(in: "tap(\"#a\").type(\"x\")").count, 1)
        XCTAssertEqual(Self.redundantTypeForms(in: "type(\"#a\", \"x\")\ntap(\"#ok\")").count, 0)
    }

    func testAgentFacingExamplesUseTheSelectorForm() throws {
        let pages = [".claude/skills/fleetest-scenario/SKILL.md",
                     "docs/user-docs/reference/tools/agent_guide.md",
                     "docs/user-docs/reference/tools/agent_guide_ja.md"]
        for page in pages {
            let text = try String(contentsOf: root.appendingPathComponent(page), encoding: .utf8)
            XCTAssertTrue(text.contains("type("), "\(page) を読めていない(走査が空振りしている)")
            XCTAssertEqual(Self.redundantTypeForms(in: text), [],
                           "\(page): 入力の見本は type(selector, text) で書く")
        }
    }

    func testIndexSummaryPrefersTheSelectorForm() throws {
        let summary = try XCTUnwrap(DSLCommandIndex.all.first { $0.name == "type" }).summary
        XCTAssertTrue(summary.contains("Prefer type(selector, text)"), summary)
    }
}
