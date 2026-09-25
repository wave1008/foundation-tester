// structuredContent は**既定では出さない**(Claude Code は structuredContent があると文面と画像を捨てる)。
// 利用者が FT_MCP_STRUCTURED_CONTENT=1 にし、交渉した版が 2025-06-18 以降のときだけ出す。
// どちらの場合も、ツールが混ぜた目印の要素はクライアントへ出さない。

import XCTest
@testable import fleetest_mcp

final class MCPStructuredContentTests: XCTestCase {

    private let content: [[String: Any]] = [
        ["type": "text", "text": "▶ A.S0010"],
        MCPServer.structuredMarker(["passed": 1, "failed": 0]),
        ["type": "image", "data": "AAAA", "mimeType": "image/jpeg"],
    ]

    func testMarkerIsAlwaysStrippedAndNotEmittedByDefault() throws {
        let result = MCPServer.toolCallResult(.success(content))
        let returned = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(returned.map { $0["type"] as? String }, ["text", "image"], "目印が content に残った")
        XCTAssertNil(result["structuredContent"], "既定で structuredContent を出してはいけない")
    }

    func testEmittedWhenEnabledAndTheTextAndImagesStay() throws {
        let result = MCPServer.toolCallResult(.success(content), emitStructured: true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["passed"] as? Int, 1)
        let returned = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(returned.map { $0["type"] as? String }, ["text", "image"])
    }

    func testFailuresCarryTheirStructuredSummaryToo() throws {
        let result = MCPServer.toolCallResult(.failure(MCPToolFailure(content: content)), emitStructured: true)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNotNil(result["structuredContent"])
    }

    func testOnlyWhenOptedInAndTheNegotiatedVersionDefinesIt() {
        XCTAssertTrue(MCPServer.emitsStructuredContent(environment: "1", negotiatedVersion: "2025-06-18"))
        XCTAssertFalse(MCPServer.emitsStructuredContent(environment: nil, negotiatedVersion: "2025-06-18"))
        XCTAssertFalse(MCPServer.emitsStructuredContent(environment: "true", negotiatedVersion: "2025-06-18"))
        XCTAssertFalse(MCPServer.emitsStructuredContent(environment: "1", negotiatedVersion: "2024-11-05"))
        XCTAssertFalse(MCPServer.emitsStructuredContent(environment: "1", negotiatedVersion: nil))
    }

    func testScenarioRunSummaryShape() throws {
        let summary = MCPServer.scenarioRunSummary([
            (id: "A.S0010", passed: true, reportPath: "/r/a.md"),
            (id: "A.S0020", passed: false, reportPath: nil),
        ])
        XCTAssertEqual(summary["passed"] as? Int, 1)
        XCTAssertEqual(summary["failed"] as? Int, 1)
        let rows = try XCTUnwrap(summary["scenarios"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["reportPath"] as? String, "/r/a.md")
        XCTAssertNil(rows.last?["reportPath"])
        XCTAssertEqual(rows.last?["passed"] as? Bool, false)
    }
}
