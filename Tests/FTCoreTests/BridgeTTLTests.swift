// FT_BRIDGE_TTL の解釈規則(BridgeAPI.resolvedBridgeTTLSeconds)。
// 0 = 無効、未設定・空・非整数・負 = 既定値。Java 側 BridgeInstrumentation.parseTTL と同規則
// (既定値の一致は AndroidBridgeVersionSyncTests が守る)。

import XCTest
import FTCore

final class BridgeTTLTests: XCTestCase {

    func testExplicitSecondsArePassedThrough() {
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("7200"), 7200)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("300"), 300)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("1"), 1)
    }

    func testZeroDisables() {
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("0"), 0)
    }

    func testInvalidValuesFallBackToDefault() {
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds(nil), BridgeAPI.bridgeTTLSecondsDefault)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds(""), BridgeAPI.bridgeTTLSecondsDefault)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("abc"), BridgeAPI.bridgeTTLSecondsDefault)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("-5"), BridgeAPI.bridgeTTLSecondsDefault)
        XCTAssertEqual(BridgeAPI.resolvedBridgeTTLSeconds("1.5"), BridgeAPI.bridgeTTLSecondsDefault)
    }
}
