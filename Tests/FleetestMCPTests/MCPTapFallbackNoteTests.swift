// ブリッジの `/tap` が返す note(例: 「activate 不発 → 合成タッチ」— `BridgeClient.tap(ref:)` の
// `lastActionNote`)は MCP の応答にも載せる。DSL は同じ値を `StepExecutor+Actions.swift` の
// `driverFallback` へ運ぶので、捨てると MCP 経由の探索者だけがこの事実を見えない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTapFallbackNoteTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    func testRefTapSurfacesTheBridgesFallbackNote() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedActionNote = "activate did not register — sent a synthetic touch instead"

        let result = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let text = body(result)
        XCTAssertTrue(text.contains("activate did not register — sent a synthetic touch instead"),
                      text)
    }

    /// **陰性対照**: ブリッジが何も注記していなければ、余計な括弧書きを足さない
    func testRefTapAddsNothingWhenTheBridgeHasNoNote() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedActionNote = nil

        let result = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let text = body(result)
        XCTAssertTrue(text.hasPrefix("tap [1] done."), text)
        XCTAssertFalse(text.contains("()"), text)
    }
}
