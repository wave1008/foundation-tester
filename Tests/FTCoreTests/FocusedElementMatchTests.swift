// XCUITest ランナーが焦点の要素に `focused` の印を付ける突き合わせ。frame の完全一致だけだと secure 欄・横向きで
// 印が付かず、ホストが「焦点は別の所」と誤って救済を撃つ

import XCTest
@testable import FTCore

final class FocusedElementMatchTests: XCTestCase {

    private func element(_ ref: Int, id: String?, _ frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "SecureTextField", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: 1)
    }

    func testUniqueIdentifierMatchesEvenWhenTheFrameDisagrees() {
        let elements = [element(1, id: "user", FTRect(x: 20, y: 100, width: 300, height: 44)),
                        element(2, id: "password", FTRect(x: 20, y: 160, width: 300, height: 44))]
        let focused = FTRect(x: 160, y: 20, width: 44, height: 300)
        XCTAssertEqual(FocusedElementMatch.index(identifier: "password", frame: focused, in: elements), 1)
    }

    func testFrameWithinSubPointRoundingMatches() {
        let elements = [element(1, id: nil, FTRect(x: 20, y: 160, width: 300, height: 44))]
        XCTAssertEqual(FocusedElementMatch.index(identifier: "", frame: FTRect(x: 20.4, y: 159.6, width: 300.33, height: 44),
                                                 in: elements), 0)
    }

    func testFrameFarOffDoesNotMatch() {
        let elements = [element(1, id: nil, FTRect(x: 20, y: 160, width: 300, height: 44))]
        XCTAssertNil(FocusedElementMatch.index(identifier: nil, frame: FTRect(x: 20, y: 163, width: 300, height: 44),
                                               in: elements))
    }

    /// 曖昧なら印を付けない(別の要素に付けると、焦点の要素を取り違えて救済・読み返しが別の欄へ向く)
    func testAmbiguousCandidatesYieldNoMatch() {
        let frame = FTRect(x: 20, y: 160, width: 300, height: 44)
        let elements = [element(1, id: "dup", frame), element(2, id: "dup", frame)]
        XCTAssertNil(FocusedElementMatch.index(identifier: "dup", frame: frame, in: elements))
    }
}
