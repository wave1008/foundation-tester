// レビュー指摘(2026-08-15): 打ち切りの逃げ道文言(`FTCore.SnapshotTruncation.remedy` の
// switch)が truncationHint と truncationNote(MCPServer+Hints.swift)の2箇所に手書きされ、
// 大文字・後続句が食い違っていた。編集点を private ヘルパ1つに集めたので、
// **バイト列が変わっていないこと**を両呼び手の出力経由で固定する(将来の文言調整を
// 意識的な操作にする回帰ゲート)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TruncationEscapeWordingTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func snapshot(kept: Int, truncated: Int) -> SnapshotResponse {
        let elements = (0..<kept).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                                truncatedCount: truncated)
    }

    // MARK: - raiseLimit(まだ上限を上げられる)

    func testHintRaiseLimitWordingIsUnchanged() {
        let snap = snapshot(kept: 120, truncated: 60)
        XCTAssertEqual(SnapshotTruncation.remedy(for: snap), .raiseLimit(to: 200))
        XCTAssertEqual(MCPServer.truncationHint(snap),
            " (the tree was truncated at 120 elements; 60 more were omitted — the element you are"
            + " looking for may be among them; scrolling will not bring them back, read again with"
            + " ft_snapshot maxElements: 200)")
    }

    func testNoteRaiseLimitWordingIsUnchanged() {
        let snap = snapshot(kept: 120, truncated: 60)
        XCTAssertEqual(MCPServer.truncationNote(snap),
            "note: 60 element(s) were dropped by the snapshot limit — they are gone from the tree,"
            + " not just hidden, so waitFor/ft_scroll_to will never find them. Read again with"
            + " ft_snapshot maxElements: 200 to get them, or narrow the screen (close a sheet,"
            + " scroll a big list away).\n")
    }

    // MARK: - narrowTheScreen(既に天井)

    func testHintNarrowTheScreenWordingIsUnchanged() {
        let snap = snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 179)
        XCTAssertEqual(SnapshotTruncation.remedy(for: snap), .narrowTheScreen)
        XCTAssertEqual(MCPServer.truncationHint(snap),
            " (the tree was truncated at 400 elements; 179 more were omitted — the element you are"
            + " looking for may be among them; scrolling will not bring them back, raising the"
            + " limit will not help (already at the 400-element ceiling) — narrow the screen"
            + " (close a sheet, scroll a big list away))")
    }

    func testNoteNarrowTheScreenWordingIsUnchanged() {
        let snap = snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 179)
        XCTAssertEqual(MCPServer.truncationNote(snap),
            "note: 179 element(s) were dropped by the snapshot limit — they are gone from the"
            + " tree, not just hidden, so waitFor/ft_scroll_to will never find them. Raising the"
            + " limit will not help (already at the 400-element ceiling) — narrow the screen"
            + " (close a sheet, scroll a big list away).\n")
    }

    // MARK: - 両 style は同じ suggestedLimit を出す

    /// raiseLimit の値は `SnapshotTruncation.suggestedLimit` の1箇所からしか来ないので、
    /// 2つの switch が同じ値を写していることをここでも固定する(片方だけ古い値のまま、
    /// という食い違いを検出する)
    func testBothStylesQuoteTheSameSuggestedLimit() {
        let snap = snapshot(kept: 120, truncated: 60)
        let expected = SnapshotTruncation.suggestedLimit(snap)
        XCTAssertEqual(expected, 200, "前提: この kept/truncated の組み合わせで検算していること")
        XCTAssertTrue(MCPServer.truncationHint(snap).contains("maxElements: \(expected)"),
                      MCPServer.truncationHint(snap))
        XCTAssertTrue(MCPServer.truncationNote(snap).contains("maxElements: \(expected)"),
                      MCPServer.truncationNote(snap))
    }

    // MARK: - 表示は budgetedCount を印字する(2026-08-15 のレビュー指摘)。生の
    // `snapshot.elements.count` を印字すると、bulk が乗った木では勧める上限より大きい数字が
    // 出て、読み手には矛盾として映る(例: "truncated at 420 elements" なのに
    // "read again with maxElements: 200")

    private func snapshotWithBulk(kept: Int, truncated: Int, bulkExempt: Int) -> SnapshotResponse {
        let keptElements = (0..<kept).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        let bulkElements = (0..<bulkExempt).map { index in
            ElementInfo(ref: kept + index + 1, type: "staticText", identifier: "bulk", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(kept + index), width: 10, height: 10), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: keptElements + bulkElements, truncatedCount: truncated,
                                bulkExemptCount: bulkExempt > 0 ? bulkExempt : nil)
    }

    /// bulk 入りの木では budgetedCount(=120)を印字し、内訳句を添える。**破ると落ちる**:
    /// 表示を `elements.count` に戻す変異は 420 を印字するので "truncated at 120" が外れる
    func testHintPrintsBudgetedCountWithBulkBreakdownWhenBulkIsPresent() {
        let snap = snapshotWithBulk(kept: 120, truncated: 60, bulkExempt: 300)
        XCTAssertEqual(SnapshotTruncation.remedy(for: snap), .raiseLimit(to: 200))
        let hint = MCPServer.truncationHint(snap)
        XCTAssertTrue(hint.contains("truncated at 120 elements (plus 300 bulk-exempt elements"
                                    + " outside the budget);"), hint)
        // 不整合そのものの回帰: 印字した件数(120)が read again の maxElements(200)を超えない
        XCTAssertTrue(hint.contains("maxElements: 200"), hint)
    }

    /// bulk が無い木では内訳句が出ない(既存のピンテストがバイト単位で確認している
    /// bulk==0 経路と同じであることの裏返し)
    func testHintOmitsBulkBreakdownWhenThereIsNoBulk() {
        let snap = snapshot(kept: 120, truncated: 60)
        XCTAssertFalse(MCPServer.truncationHint(snap).contains("bulk-exempt"),
                       MCPServer.truncationHint(snap))
    }
}
