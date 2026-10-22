// MCP の iOS は常に XCUITest(`MCPBridgeFollowingTests` が経路を固定)。ツールの説明文が「profile: を渡せば
// 別のモードになる」と存在しない切替を案内していた(ft_double_tap・ft_pinch)ので、説明文の側を縛る。

import XCTest
@testable import fleetest_mcp

final class IOSModeWordingTests: XCTestCase {

    private func description(_ tool: String) -> String {
        MCPServer.toolDefinitions.first { $0["name"] as? String == tool }?["description"] as? String ?? ""
    }

    func testNoToolDescriptionPromisesAModeSwitchThroughProfile() {
        let offenders = MCPServer.toolDefinitions.compactMap { def -> String? in
            guard let name = def["name"] as? String, let text = def["description"] as? String,
                  text.contains("pass profile:") else { return nil }
            return name
        }
        XCTAssertEqual(offenders, [], "MCP の iOS は profile を渡しても XCUITest: \(offenders)")
        XCTAssertTrue(description("ft_double_tap").contains("XCUITest only"), description("ft_double_tap"))
    }

    func testRunScenarioNoteSaysWhichBridgeRan() {
        XCTAssertTrue(MCPServer.iosXCUITestBridgeNote.contains("XCUITest bridge"))
        XCTAssertTrue(MCPServer.iosXCUITestBridgeNote.contains("iOS mode"))
    }
}
