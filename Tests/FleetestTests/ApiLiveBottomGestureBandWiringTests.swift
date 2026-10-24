// ライブ操作の ref の tap / doubleTap が、Android の下端のジェスチャ帯を避ける判定(`BottomGestureBandTap` = DSL・MCP と共有)を
// 通していることをソース走査で固定する(DSL にだけ入れていた = 同じ画面でライブ操作だけホームへ抜けた)

import XCTest

final class ApiLiveBottomGestureBandWiringTests: XCTestCase {

    private func caseBody(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "        case \"\(name)\":"), "case \"\(name)\" を拾えていない")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        case \"")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    func testRefTapAndDoubleTapClearTheBottomGestureBand() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(try caseBody("tap", in: source).contains("bottomBandPoint(ref:"))
        XCTAssertTrue(try caseBody("doubleTap", in: source).contains("BottomGestureBandTap.tapY("))
    }
}
