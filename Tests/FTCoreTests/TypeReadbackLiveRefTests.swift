// TypeReadback.match(of:in:) は value(of:in:) と同じ突き合わせ(value はブリッジの入力なので触らずに別ファイルで持つ)
import XCTest
@testable import FTCore

final class TypeReadbackLiveRefTests: XCTestCase {
    private func field(_ ref: Int, id: String?, value: String?, y: Double = 0) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 100, height: 20), depth: 0)
    }

    func testMatchAgreesWithValue() {
        let target = field(1, id: "f", value: nil)
        let unnamed = field(1, id: nil, value: nil, y: 40)
        let cases: [(ElementInfo, [ElementInfo])] = [
            (target, [field(3, id: "other", value: "x"), field(7, id: "f", value: "abc")]),   // identifier で1つ
            (target, [field(3, id: "f", value: "a"), field(7, id: "f", value: "b")]),         // 曖昧 = nil
            (target, [field(3, id: "other", value: "a")]),                                   // 無い = nil
            (unnamed, [field(2, id: nil, value: "z", y: 40), field(5, id: nil, value: "q", y: 80)]),  // frame で1つ
        ]
        for (t, elements) in cases {
            XCTAssertEqual(TypeReadback.match(of: t, in: elements).map(TypeReadback.normalizedValue(of:)),
                           TypeReadback.value(of: t, in: elements))
        }
        XCTAssertEqual(TypeReadback.match(of: target, in: cases[0].1)?.ref, 7)
        XCTAssertEqual(TypeReadback.match(of: unnamed, in: cases[3].1)?.ref, 2)
    }
}
