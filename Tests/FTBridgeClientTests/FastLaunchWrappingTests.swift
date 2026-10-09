// FastLaunchDriver を被せるかの判定(`FastLaunchDriver.wrapping`)と、それを3つの経路が共有していること。
// MCP は以前この判定を持たず、毎回 `XCUIApplication.launch()`(実測 6.6s。被せると 4.4s)を払っていた
// = DSL 側の高速化が MCP に届かない型。経路を足したらここの一覧にも足す。

import XCTest
@testable import FTBridgeClient

final class FastLaunchWrappingTests: XCTestCase {

    func testWrapsOnlyWhenASimulatorUDIDIsKnown() {
        let client = BridgeClient(port: 1)
        XCTAssertTrue(FastLaunchDriver.wrapping(client, simulatorUDID: "61A7E615-9C85-438E-BE3D-1BAC78640B11")
                      is FastLaunchDriver)
        XCTAssertTrue(FastLaunchDriver.wrapping(client, simulatorUDID: nil) is BridgeClient,
                      "実機・udid 不明は素の launch(CoreSimulator / simctl に依存できない)")
        XCTAssertTrue(FastLaunchDriver.wrapping(client, simulatorUDID: "") is BridgeClient)
    }

    /// **XCUITest のドライバを組む経路は全部この判定を通す**(1つでも素の BridgeClient を組むと、その経路だけ起動が約 2 秒遅い)
    func testEveryXCUITestDriverPathUsesTheSharedDecision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
                     "Sources/fleetest-mcp/MCPServer+Driver.swift",
                     "Sources/FTBridgeClient/ExploreDriverResolver.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("FastLaunchDriver.wrapping("), "\(path) が FastLaunchDriver.wrapping を通っていない")
        }
    }
}
