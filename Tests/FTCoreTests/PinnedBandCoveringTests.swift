// 貼り付く見出しの下に潜った行は、木の並びでは見出しが奥に出るので遮蔽の判定が拾えない。
// 撃つ前の送りは「容器の縁に貼り付いた名前つきの帯が中心を覆う」形で見つける。
// 木は E2EX-RN の sticky(XCUITest)で上へ探して止まった実物の枠

import XCTest
@testable import FTCore

final class PinnedBandCoveringTests: XCTestCase {

    private func e(_ ref: Int, _ type: String, _ id: String, y: Double, x: Double = 32, w: Double = 338,
                   h: Double = 44, depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private let container = FTRect(x: 16, y: 157, width: 370, height: 701)

    private var tree: [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: container, depth: 1, scrollable: true),
         e(2, "button", "row_s_B0", y: 111),
         e(3, "staticText", "hdr_B", y: 157, x: 16, w: 370, h: 33),
         e(4, "button", "row_s_B1", y: 159),
         e(5, "button", "row_s_B2", y: 207)]
    }

    func testRowWhoseCentreIsUnderThePinnedHeaderIsCovered() {
        let b1 = tree[3]
        XCTAssertEqual(TapTargetGeometry.pinnedBandCovering(b1, in: tree, container: container)?.identifier, "hdr_B")
        let jump = TapTargetGeometry.uncoverScrollJump(target: b1, coveredBy: tree[2], container: container)
        XCTAssertNotNil(jump)
        XCTAssertLessThan(jump ?? 0, 0, "上の帯 = 中身を下へ戻す")
    }

    func testRowBelowTheHeaderIsNotCovered() {
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(tree[4], in: tree, container: container))
    }

    func testBandAwayFromTheEdgeIsNotPinned() {
        var moved = tree
        moved[2] = e(3, "staticText", "hdr_B", y: 170, x: 16, w: 370, h: 33)
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(moved[3], in: moved, container: container))
    }

    func testTheHeaderItselfIsNotItsOwnCover() {
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(tree[2], in: tree, container: container))
    }

    // ---- 文字の幅しか申告しない見出し(Flutter の sticky・XCUITest の実物の枠: 容器 0,170 402x704) ----

    private let flutterContainer = FTRect(x: 0, y: 170, width: 402, height: 704)

    private var flutterTree: [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: flutterContainer, depth: 1, scrollable: true),
         e(2, "button", "row_s_F3", y: 170, x: 0, w: 402, h: 54),
         e(3, "button", "row_s_F4", y: 224, x: 0, w: 402, h: 56),
         e(4, "staticText", "hdr_F", y: 180, x: 16, w: 83, h: 20)]
    }

    func testNarrowHeaderTextIsWidenedToTheDrawnBand() throws {
        let band = try XCTUnwrap(TapTargetGeometry.pinnedBandCovering(flutterTree[1], in: flutterTree,
                                                                      container: flutterContainer))
        XCTAssertEqual(band.identifier, "hdr_F")
        XCTAssertEqual(band.frame, FTRect(x: 0, y: 170, width: 402, height: 40), "描画の帯 170..210(文字の上下に 10)")
        XCTAssertNotNil(TapTargetGeometry.uncoverScrollJump(target: flutterTree[1], coveredBy: band,
                                                            container: flutterContainer))
    }

    func testRowBelowTheNarrowHeaderIsNotCovered() {
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(flutterTree[2], in: flutterTree, container: flutterContainer))
    }

    /// 上端の行が自分のラベル(兄弟として出た文字)を見出しと読まない
    func testTheRowsOwnLabelIsNotAHeader() {
        let row = ElementInfo(ref: 2, type: "button", identifier: "row_a5", label: "行 A5", value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 170, width: 402, height: 56), depth: 2)
        let label = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "行 A5", value: nil, placeholder: nil,
                                enabled: true, frame: FTRect(x: 16, y: 186, width: 43, height: 24), depth: 2)
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(row, in: [flutterTree[0], row, label],
                                                          container: flutterContainer))
    }

    /// 容器の上端から離れた文字(普通に並んだ見出し)は帯にしない
    func testTextAwayFromTheTopIsNotAPinnedHeader() {
        var tree = flutterTree
        tree[3] = e(4, "staticText", "hdr_F", y: 200, x: 16, w: 83, h: 20)
        tree[1] = e(2, "button", "row_s_F3", y: 190, x: 0, w: 402, h: 54)
        XCTAssertNil(TapTargetGeometry.pinnedBandCovering(tree[1], in: tree, container: flutterContainer))
    }
}
