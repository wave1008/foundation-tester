// `ft_type {replace:true}` は下書き(`ft_draft_scenario`)にも `replace: true` を記録すること
// (2026-08-12)。取りこぼすと、対話的に検証した replace 操作が下書きでは通常の追記
// (`type(sel, text)`)1行に化ける。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPTypeReplaceDraftTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testDraftRecordsReplaceWhenFtTypeUsesIt() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc", "replace": true])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("type(\"#login_btn\", \"abc\", replace: true)"), text)
    }

    /// replace 未指定の通常呼び出しでは "replace: true" が出ないこと(退行防止)
    func testDraftDoesNotRecordReplaceForPlainType() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("type(\"#login_btn\", \"abc\")"), text)
        XCTAssertFalse(text.contains("replace:"), text)
    }
}
