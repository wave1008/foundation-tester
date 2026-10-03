// udid だけを渡した呼び出しは MCP がその回のポートへ解決して engineKey に載せる(injectingPort)ので、
// 別宛先の拒否文は「このポートを指した」と言い切らず、udid がそこへ解決されたと言い添える
// (2026-10-03 負荷テスト: sim-08 の in-app と xcuitest を udid だけで行き来して 33 回出た)

import XCTest
@testable import fleetest_mcp

final class RefFromAnotherTargetUDIDTests: XCTestCase {
    // MARK: - ④ udid だけの呼び出しへの別宛先の拒否文

    func testRefFromAnotherTargetMentionsTheUDIDResolution() {
        let withUDID = MCPServer.refFromAnotherTargetMessage(
            ref: 28, takenUnder: "direct:ios:8139:", firedAt: "direct:ios:8138:", udid: "UDID-1")
        XCTAssertTrue(withUDID.contains("but this call addressed direct:ios:8138: (this call gave udid UDID-1,"
            + " which resolved to that port this time"), withUDID)
        let withoutUDID = MCPServer.refFromAnotherTargetMessage(
            ref: 28, takenUnder: "direct:ios:8139:", firedAt: "direct:ios:8138:", udid: nil)
        XCTAssertTrue(withoutUDID.contains("but this call addressed direct:ios:8138: — refusing"), withoutUDID)
        XCTAssertFalse(withoutUDID.contains("udid"))
    }
}
