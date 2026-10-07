// 覆いを外す送りのドラッグは、始点が入力欄に乗ると SwiftUI でスクロールにならない(何も動かない)。
// 木は E2EX-iOS「入力の種類」でキーボードを出した実物の枠(送る領域 = キーボードの上 0..538)

import XCTest
@testable import FTCore

final class DragStartAvoidingTextInputsTests: XCTestCase {

    private func field(_ ref: Int, y: Double, h: Double = 34) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: "f\(ref)", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: h), depth: 2)
    }

    private var tree: [ElementInfo] {
        [field(1, y: 106, h: 33), field(2, y: 184, h: 33), field(3, y: 267, h: 64),
         field(4, y: 379), field(5, y: 425), field(6, y: 503)]
    }
    private let area = FTRect(x: 0, y: 0, width: 402, height: 538)

    func testStartOnAFieldMovesToTheNearestGapAboveOrBelow() throws {
        // 実測の始点 457(「名」425..459 の上)
        let y = try XCTUnwrap(TapTargetGeometry.dragStartAvoidingTextInputs(
            fromY: 457, x: 201, distance: 54, fingerUp: true, area: area, elements: tree))
        XCTAssertEqual(y, 463, "欄の下の縁のすぐ外(459 + 4)が最も近い")
        XCTAssertFalse(tree.contains { y >= $0.frame.y && y <= $0.frame.y + $0.frame.height })
    }

    func testStartOffAnyFieldIsKept() {
        XCTAssertEqual(TapTargetGeometry.dragStartAvoidingTextInputs(
            fromY: 360, x: 201, distance: 54, fingerUp: true, area: area, elements: tree), 360)
    }

    func testFieldOutsideTheDragColumnIsIgnored() {
        XCTAssertEqual(TapTargetGeometry.dragStartAvoidingTextInputs(
            fromY: 457, x: 395, distance: 54, fingerUp: true, area: area, elements: tree), 457)
    }

    func testCandidateMustLeaveRoomForTheWholeDrag() throws {
        // 指を上へ 54 送るなら始点は 54 以上。欄 1 の上(102)は置けても、0..54 の帯には置けない
        let y = try XCTUnwrap(TapTargetGeometry.dragStartAvoidingTextInputs(
            fromY: 120, x: 201, distance: 54, fingerUp: true, area: area, elements: tree))
        XCTAssertEqual(y, 102)
        XCTAssertNil(TapTargetGeometry.dragStartAvoidingTextInputs(
            fromY: 120, x: 201, distance: 54, fingerUp: true, area: area,
            elements: [field(9, y: 0, h: 538)]), "全面が欄なら置き場が無い")
    }
}
