// プロファイル無し・`port:` だけの iOS Simulator でも、ft_run_scenario のデバイスの印(lease)の鍵に
// なる udid が connection に載ること。載らないと印が書かれず、run が MCP のデバイスを避けられない。

import XCTest
import FTBridgeClient
@testable import fleetest_mcp

final class MCPRunScenarioPortOnlyUDIDTests: XCTestCase {

    func testExplicitUDIDWinsOverTheBridgeReportedOne() {
        XCTAssertEqual(PortDirectIOSTarget.simulatorUDID(explicit: "A", reported: "B"), "A")
    }

    func testBridgeReportedUDIDFillsInWhenNoneIsGiven() {
        XCTAssertEqual(PortDirectIOSTarget.simulatorUDID(explicit: nil, reported: "B"), "B")
        XCTAssertEqual(PortDirectIOSTarget.simulatorUDID(explicit: "", reported: "B"), "B")
    }

    func testNoUDIDAnywhereStaysNil() {
        XCTAssertNil(PortDirectIOSTarget.simulatorUDID(explicit: nil, reported: nil))
        XCTAssertNil(PortDirectIOSTarget.simulatorUDID(explicit: "", reported: ""))
    }

    /// 配線: ft_run_scenario の iOS 直指定が、ブリッジ申告の udid を connection へ渡している
    func testRunScenarioWiresTheBridgeReportedUDIDIntoTheConnection() throws {
        let code = try MCPServerSourceText.combined()
        XCTAssertTrue(code.contains("directTarget.reportedSimulatorUDID()")
                      && code.contains("directTarget.connection(simulatorUDID: simulatorUDID)"),
                      "ft_run_scenario がポートに結び付いた udid を connection へ渡していない")
    }
}
