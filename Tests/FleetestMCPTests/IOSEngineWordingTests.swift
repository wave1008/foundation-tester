// MCP の iOS は常に XCUITest(`MCPEngineFollowingTests` が経路を固定)。ツールの説明文が「profile: を渡せば
// 別のエンジンになる」と存在しない切替を案内していた(ft_double_tap・ft_pinch)ので、説明文の側を縛る。

import XCTest
@testable import fleetest_mcp

final class IOSEngineWordingTests: XCTestCase {

    private func description(_ tool: String) -> String {
        MCPServer.toolDefinitions.first { $0["name"] as? String == tool }?["description"] as? String ?? ""
    }

    func testNoToolDescriptionPromisesAnEngineSwitchThroughProfile() {
        let offenders = MCPServer.toolDefinitions.compactMap { def -> String? in
            guard let name = def["name"] as? String, let text = def["description"] as? String,
                  text.contains("pass profile:") else { return nil }
            return name
        }
        XCTAssertEqual(offenders, [], "MCP の iOS は profile を渡しても XCUITest: \(offenders)")
        XCTAssertTrue(description("ft_double_tap").contains("XCUITest only"), description("ft_double_tap"))
    }

    func testRunScenarioNoteSaysWhichEngineRan() {
        XCTAssertTrue(MCPServer.iosXCUITestEngineNote.contains("XCUITest engine"))
        XCTAssertTrue(MCPServer.iosXCUITestEngineNote.contains("hybrid"))
    }
}
