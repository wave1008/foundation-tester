// iOS: 容器の下端で見切れた要素は、撃つ前に全体が見えるまで上へ送る(中心が描かれていない所に落ちて焦点が立たない)。
// 木は E2EX-CMP「入力の種類」の実物の枠(`#field_bottom` だけ高さ 46・他の欄は 64)

import XCTest
@testable import FTCore

final class BottomEdgeClipLiftTests: XCTestCase {

    private func field(_ ref: Int, _ id: String, y: Double, h: Double = 64) -> ElementInfo {
        ElementInfo(ref: ref, type: "textView", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: h), depth: 2)
    }

    private var tree: [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1, scrollable: true),
         field(2, "field_number", y: 322), field(3, "field_password", y: 398), field(4, "field_first", y: 598),
         field(5, "field_second", y: 675), field(6, "field_auto", y: 751), field(7, "field_bottom", y: 827, h: 46)]
    }

    func testFieldCutOffAtTheBottomEdgeIsLifted() throws {
        let bottom = tree.first { $0.identifier == "field_bottom" }!
        let jump = try XCTUnwrap(TapTargetGeometry.bottomEdgeClipLift(bottom, in: tree))
        XCTAssertGreaterThanOrEqual(jump, 64 - 46, "欠けた高さ以上は送る")
    }

    func testFullyDrawnFieldIsNotLifted() {
        let auto = tree.first { $0.identifier == "field_auto" }!
        XCTAssertNil(TapTargetGeometry.bottomEdgeClipLift(auto, in: tree))
    }
}
