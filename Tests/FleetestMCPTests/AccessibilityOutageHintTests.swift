// XCTest の a11y サーバが一時的に落ちた(500 + kAXErrorAPIDisabled)ときの MCP の出口。
// run は同じ判定(`SessionRecoveryDriver.isAccessibilityTemporarilyDown`)で結果を捨てて振り直すが、
// MCP は呼び手が次の一手を打つ場なので「環境要因・数秒で戻る・待ってから再試行」を言う。
// 実地 2026-09-23 の負荷テスト: 生の
// `Error Domain=com.apple.dt.xctest.automation-support.error Code=8 "Error getting main window
// kAXErrorAPIDisabled"` だけが返り、呼び手にはアプリの不具合と区別が付かなかった。

import FTBridgeClient
import FTCore
import XCTest
@testable import fleetest_mcp

final class AccessibilityOutageHintTests: XCTestCase {

    private func outage() -> Error {
        DriverError.badResponse(
            status: 500,
            body: "Error Domain=com.apple.dt.xctest.automation-support.error Code=8"
                + " \"Error getting main window kAXErrorAPIDisabled\"")
    }

    func testHintIsAddedForTheAccessibilityOutage() {
        let hint = MCPServer.accessibilityOutageHint(outage())
        XCTAssertFalse(hint.isEmpty)
        XCTAssertTrue(hint.contains("kAXErrorAPIDisabled"), hint)
        XCTAssertTrue(hint.contains("environment"), hint)
        XCTAssertTrue(hint.lowercased().contains("try again"), hint)
    }

    /// 他の失敗には足さない(全部の失敗に同じ注記が付くと読み飛ばされる)
    func testNoHintForOtherFailures() {
        XCTAssertTrue(MCPServer.accessibilityOutageHint(
            DriverError.badResponse(status: 500, body: "something else")).isEmpty)
        XCTAssertTrue(MCPServer.accessibilityOutageHint(
            DriverError.badResponse(status: 422, body: "kAXErrorAPIDisabled")).isEmpty)
    }
}
