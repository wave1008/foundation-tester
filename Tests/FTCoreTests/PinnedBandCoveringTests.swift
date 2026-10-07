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
}
