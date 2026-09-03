// FM へ渡す木の上限(FMPromptBudget)の契約。
// **収まる木は1バイトも変えない**のが最重要 —— 木を削ると分類が変わる(実測: 40 行に切り詰めた
// triage は 36 件中 11 件で failureClass が変わり、locatorDrift は 7 件 → 0 件になった)。
// 切るのは「今日どのみち呼び出しごと失敗する」溢れた木だけ。

import XCTest
@testable import FTFoundationModels

final class FMPromptBudgetTests: XCTestCase {

    /// 上限は文字数。根拠は 1.40〜1.48 文字/トークンの実測(**期待値はリテラルで書く** ——
    /// production の定数を参照すると値を変える変異が素通りする)
    func testBudgetIsPinned() {
        XCTAssertEqual(FMPromptBudget.treeCharacterBudget, 3_600)
    }

    func testShortTreeIsUntouched() {
        let tree = "screen: 402x874\n[1] staticText \"ホーム\" id=txt_home (16,78 48x20)"
        XCTAssertEqual(FMPromptBudget.fit(tree), tree, "収まる木を書き換えている")
    }

    func testExactlyAtTheBudgetIsUntouched() {
        let line = String(repeating: "a", count: 99)
        let tree = ([String(repeating: "h", count: 100)] + Array(repeating: line, count: 30))
            .joined(separator: "\n")   // 100 + 30*100 = 3,100 文字
        XCTAssertLessThanOrEqual(tree.count, FMPromptBudget.treeCharacterBudget)
        XCTAssertEqual(FMPromptBudget.fit(tree), tree)
    }

    func testOversizedTreeIsCutToTheBudgetAndSaysSo() {
        let header = "screen: 402x874"
        let labelled = (1...400).map { "[\($0)] staticText \"行 \($0)\" id=row_\($0) (16,\($0) 48x20)" }
        let tree = ([header] + labelled).joined(separator: "\n")
        XCTAssertGreaterThan(tree.count, FMPromptBudget.treeCharacterBudget, "前提: 溢れる木")
        let fitted = FMPromptBudget.fit(tree)
        XCTAssertTrue(fitted.hasPrefix(header), "先頭行(画面サイズ)を落としている")
        XCTAssertLessThanOrEqual(fitted.count - fitted.split(separator: "\n").last!.count,
                                 FMPromptBudget.treeCharacterBudget,
                                 "注記を除いた本体が上限を超えている")
        XCTAssertTrue(fitted.contains("more line(s) omitted"), "切ったことを明示していない")
        XCTAssertTrue(fitted.contains("absence here does not mean the element is missing"),
                      "「無いように見えるだけ」の注意が無いと、モデルは要素が存在しないと読む")
    }

    /// **木を渡す FM 経路は全部この上限を通す**。1つ外れると、その経路だけが密な画面で
    /// 呼び出しごと失敗し、**nil = 黙って素通り**する(実測: 実アプリの木3枚は 6/6 とも
    /// 上限なしでは失敗し、上限ありでは 6/6 とも答えを返した)
    func testEveryTreeCarryingCallSiteGoesThroughTheBudget() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/FTFoundationModels/ReplayAssist.swift"),
            encoding: .utf8)
        let renders = source.components(separatedBy: "SnapshotRenderer.render(").count - 1
        let fitted = source.components(separatedBy: "FMPromptBudget.fit(SnapshotRenderer.render(").count - 1
        XCTAssertGreaterThanOrEqual(renders, 2, "木を渡す経路が2つ未満しか見えていない = 走査が壊れている")
        XCTAssertEqual(fitted, renders,
                       "SnapshotRenderer.render の結果を上限に通さず FM へ渡している経路がある")
    }

    /// 意味を運ぶ行(ラベル / id)を優先し、**木の順序は変えない**
    func testMeaningfulLinesArePreferredInTreeOrder() {
        let header = "screen: 402x874"
        var lines: [String] = []
        for i in 1...300 {
            lines.append("[\(i)] other (0,\(i) 10x10)")   // ラベルも id も無い行
            lines.append("[\(i)] staticText \"行 \(i)\" id=row_\(i) (16,\(i) 48x20)")
        }
        let fitted = FMPromptBudget.fit(([header] + lines).joined(separator: "\n"))
        let kept = fitted.split(separator: "\n").dropFirst().dropLast().map(String.init)
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(kept.allSatisfy { $0.contains("\"") || $0.contains("id=") },
                      "ラベルも id も無い行を残している(意味を運ぶ行を落としている)")
        let refs = kept.compactMap { line -> Int? in
            guard let close = line.firstIndex(of: "]") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<close])
        }
        XCTAssertEqual(refs, refs.sorted(), "木の順序を並べ替えている")
    }
}
