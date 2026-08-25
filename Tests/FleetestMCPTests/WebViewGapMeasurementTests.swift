// webViewGapNote の帯の測り方(largestEmptyBand)を実測に直した修正(2026-08-12・作業1)の回帰。
//
// 修正前は帯の高さを60分割スライスの本数で数えており、両端のスライス(境界要素と少しでも
// 交わるスライス)が丸ごと落ちて実効閾値が縮んでいた。ここでは実測 witness
// (webView 高さ2153・y1199→1391の192px空白)で、修正前のコードなら黙ってしまう形が
// 修正後には出ることを固定する。

import XCTest
@testable import fleetest_mcp
import FTCore

final class WebViewGapMeasurementTests: XCTestCase {

    private func element(_ ref: Int, y: Double, height: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: "row \(ref)", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 1080, height: height), depth: 2)
    }

    private func tree(fillers: [(y: Double, height: Double)]) -> SnapshotResponse {
        var elements = [ElementInfo(ref: 1, type: "webView", identifier: nil, label: "page",
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 210, width: 1084, height: 2153), depth: 2,
                                    scrollable: true)]
        for (i, filler) in fillers.enumerated() {
            elements.append(element(i + 2, y: filler.y, height: filler.height))
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                elements: elements, truncatedCount: 0)
    }

    /// **回帰の witness**: 下端が y=1199、上端が y=1391 の2要素だけを置くと、間の 192px
    /// (容器 2153 の 8.92%・画面 2424 の 7.92%)が空く。修正前のコードでは同じ木で
    /// 60分割スライスの量子化により**測定値が 143.5px(6.67%)まで縮み、8% 閾値に届かず
    /// 出なかった**(手計算で確認: sliceHeight=2153/60=35.883、bestStart=28・bestCount=4 →
    /// 4*35.883=143.53)。実測値(192px)を使う修正後は 8%/5% どちらの閾値も超えるので出る
    func testARealGapWideEnoughToPassButQuantizedTooNarrowFires() {
        let snapshot = tree(fillers: [(y: 210, height: 989), (y: 1391, height: 972)])
        let note = MCPServer.webViewGapNote(snapshot)
        XCTAssertTrue(note.contains("nothing is listed between y=1199 and y=1391"), note)
        XCTAssertTrue(note.contains("a band 192 tall"), note)
    }

    /// 陰性: 同じ容器で帯を 100px(4.6%)にすると、実測値を使ってもなお閾値未満で黙る
    func testANarrowerGapStaysSilent() {
        let snapshot = tree(fillers: [(y: 210, height: 989), (y: 1299, height: 1064)])
        XCTAssertEqual(MCPServer.webViewGapNote(snapshot), "")
    }

    /// 端の帯は数えない(上端に接する300px)
    func testAGapAtTheTopIsNotReported() {
        let snapshot = tree(fillers: [(y: 510, height: 1853)])
        XCTAssertEqual(MCPServer.webViewGapNote(snapshot), "",
                       "上端に接する空白は容器の余白であって取りこぼしの証拠ではない")
    }

    /// 端の帯は数えない(下端に接する300px)
    func testAGapAtTheBottomIsNotReported() {
        let snapshot = tree(fillers: [(y: 210, height: 1853)])
        XCTAssertEqual(MCPServer.webViewGapNote(snapshot), "",
                       "下端に接する空白は容器の余白であって取りこぼしの証拠ではない")
    }

    /// **測り方そのもの**: 帯の高さ(192px)はスライス幅(35.883px)の倍数ではないが、
    /// 注記に出る y= と高さはスライス境界に丸められた値ではなく実測値そのものであること
    func testTheReportedBandIsTheRealMeasurementNotASliceMultiple() {
        let snapshot = tree(fillers: [(y: 210, height: 989), (y: 1391, height: 972)])
        let note = MCPServer.webViewGapNote(snapshot)
        let sliceHeight = 2153.0 / 60.0
        XCTAssertFalse(note.contains("\(Int((4 * sliceHeight).rounded()))"),
                       "スライス境界に丸めた高さ(≈143)が出てはいけない: \(note)")
        XCTAssertTrue(note.contains("192"), "実測の高さ(192)がそのまま出ること: \(note)")
    }
}
