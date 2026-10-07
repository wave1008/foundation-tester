// 除外条件(not)の直列化が往復で条件を変えないことを固定する。
// 1件の除外は「その全属性に一致する要素を除く」(AND)。属性が2つ以上の除外を属性1つだけ書き出すと、
// 読み直したときに除外の対象が変わる(MCP の記録・下書きは文字列へ戻して読み直す)

import XCTest
@testable import FTCore

final class FTSelectorNotSerializeTests: XCTestCase {

    private func roundTrips(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = FTSelector.parse(text).primary
        let serialized = FTSelector.serialize(parsed)
        let reparsed = FTSelector.parse(serialized).primary
        XCTAssertEqual(reparsed, parsed, "\(text) → \(serialized) で条件が変わった", file: file, line: line)
    }

    /// 型と id の組の除外(`!.button#x`)は1件のまま往復する
    func testMultiAttributeExclusionRoundTrips() {
        roundTrips("text=OK&&!.button#x")
    }

    /// 属性1つの除外は従来どおりの形で往復する
    func testSingleAttributeExclusionRoundTrips() {
        roundTrips("text=OK&&text!=Cancel")
        roundTrips("text=OK&&!#btn_cancel")
    }

    /// 1トークンで書けない組は属性ごとに分ける(全属性が残る = どの属性も黙って落ちない)
    func testUnrepresentableExclusionKeepsEveryAttribute() {
        let entry = FlowLocator(id: "x", label: "Cancel")
        let serialized = FTSelector.serialize(FlowLocator(label: "OK", not: [entry]))
        XCTAssertTrue(serialized.contains("id!=x"), serialized)
        XCTAssertTrue(serialized.contains("text!=Cancel"), serialized)
    }
}
