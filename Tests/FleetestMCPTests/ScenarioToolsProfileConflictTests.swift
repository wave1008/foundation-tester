import XCTest
@testable import fleetest_mcp

/// `MCPServer.profileConflict` — profile が platform/port/serial/udid と併用されたら拒否する
/// (CLI の `--profile` + `--platform/--port/--serial` 併用エラーと同じ規律を MCP へ広げたもの)。
/// **args だけを見る純粋関数を直接叩く**(呼び出し経路(runScenario 冒頭)越しではなく、
/// 判定そのものを固定する)
final class ScenarioToolsProfileConflictTests: XCTestCase {

    func testNoProfileNeverConflicts() {
        XCTAssertNil(MCPServer.profileConflict([:]))
        XCTAssertNil(MCPServer.profileConflict(["platform": "ios", "port": 8100]))
    }

    func testProfileAloneDoesNotConflict() {
        XCTAssertNil(MCPServer.profileConflict(["profile": "ios"]))
    }

    func testProfileWithPlatformConflicts() {
        let message = MCPServer.profileConflict(["profile": "ios", "platform": "ios"])
        XCTAssertEqual(message,
                       "profile cannot be combined with platform/port/serial/udid (the profile picks the device)")
    }

    func testProfileWithPortConflicts() {
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "port": 8100]))
    }

    func testProfileWithSerialConflicts() {
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "serial": "ABC123"]))
    }

    func testProfileWithUDIDConflicts() {
        // foldingUDIDIntoPort が port へ畳んでも元の "udid" キーは args に残るので、
        // ここでも拾えることを固定する
        XCTAssertNotNil(MCPServer.profileConflict(["profile": "ios", "udid": "0000-1111"]))
    }
}
