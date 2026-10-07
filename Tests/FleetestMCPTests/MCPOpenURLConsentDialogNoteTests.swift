// ft_open_url は配送後に前面のシステムアラートが観測できたら、「Delivered」だけで終わらせず
// 確認ダイアログが残っている可能性を言う。観測できない(アラート無し)ときは黙る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPOpenURLConsentDialogNoteTests: XCTestCase {

    private func run(alert: SystemAlertProbeResponse?) async throws -> String {
        let driver = FakeDriver()
        driver.scriptedSystemAlert = alert
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        return try await server.call(tool: "ft_open_url", args: ["url": "myapp://x"])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testAFrontAlertAfterDeliveryIsNamedAsAPossibleLeftoverConsentDialog() async throws {
        let text = try await run(alert: SystemAlertProbeResponse(
            present: true, title: "Open in \"App\"?", buttons: ["Cancel", "Open"]))
        XCTAssertTrue(text.contains("Delivered"), text)
        XCTAssertTrue(text.contains("automatic acceptance did not run or did not dismiss it"), text)
    }

    func testNoAlertLeavesTheDeliveryMessageUnchanged() async throws {
        let text = try await run(alert: nil)
        XCTAssertTrue(text.contains("Delivered"), text)
        XCTAssertFalse(text.contains("automatic acceptance"), text)
    }
}
