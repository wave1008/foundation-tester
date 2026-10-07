// webView の空白帯の判定(TreeCoverage.gap)。規則的に並ぶ行の行間は取りこぼしではない。実測(E2E-iOS の WebView・
// XCUITest)では 23pt の行が 73pt おきに並び、行間 50pt が容器比 8% に届いて誤って注記していた

import XCTest
@testable import FTCore

final class TreeCoverageRowRhythmTests: XCTestCase {

    private func leaf(_ ref: Int, _ label: String, y: Double, x: Double = 16, w: Double = 113, h: Double = 23,
                      type: String = "staticText") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: label, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 2)
    }

    /// E2E-iOS の WebView 画面の木(XCUITest)の frame そのまま
    private func snapshot(droppingRow02: Bool) -> SnapshotResponse {
        let container = ElementInfo(ref: 1, type: "webView", identifier: "wv_container", label: nil, value: nil,
                                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 156, width: 402, height: 622),
                                    depth: 1)
        var elements = [container,
                        leaf(2, "WebView 見出し", y: 186, h: 28), leaf(3, "WebView 本文", y: 230),
                        leaf(4, "WebView リンク", y: 269), leaf(5, "WebView 入力", y: 308, w: 333, h: 45, type: "textField"),
                        leaf(6, "送信", y: 369, w: 50, h: 45, type: "button"),
                        leaf(7, "アリアラベル", y: 430, w: 34, h: 45, type: "button"),
                        leaf(8, "変形ボタン", y: 491, x: 76, w: 98, h: 45, type: "button"),
                        leaf(9, "wv_result=-", y: 552), leaf(10, "WebView 行 01", y: 599),
                        leaf(12, "WebView 行 03", y: 745), leaf(14, "固定ボタン", y: 726, x: 296, w: 99, h: 44, type: "button")]
        if !droppingRow02 { elements.append(leaf(11, "WebView 行 02", y: 672)) }
        return SnapshotResponse(sessionBundleID: "com.example", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0,
                                offscreen: [leaf(0, "WebView 行 05", y: 891)])
    }

    func testSpacingBetweenRegularlyRepeatingRowsIsNotAGap() {
        XCTAssertNil(TreeCoverage.gap(in: snapshot(droppingRow02: false)))
    }

    /// 1行まるごと落ちると並びが途切れる(A→B が2間隔になり C と揃わない)= 今までどおり帯を言う
    func testADroppedRowStillLeavesAGap() throws {
        let gap = try XCTUnwrap(TreeCoverage.gap(in: snapshot(droppingRow02: true)))
        XCTAssertEqual(gap.bands.first?.y ?? 0, 622, accuracy: 0.5)
    }
}
