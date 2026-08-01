import XCTest
@testable import FTBridgeClient

final class IOSReduceMotionTests: XCTestCase {

    /// アニメーションを残す = Reduce Motion off("false" を書く)。反転を落とす
    func testWriteArgumentsInvertAnimationsFlag() {
        XCTAssertEqual(
            IOSReduceMotion.writeArguments(udid: "UDID-1", animationsEnabled: true),
            ["xcrun", "simctl", "spawn", "UDID-1",
             "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "false"])
        XCTAssertEqual(
            IOSReduceMotion.writeArguments(udid: "UDID-1", animationsEnabled: false),
            ["xcrun", "simctl", "spawn", "UDID-1",
             "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "true"])
    }

    func testTargetsTheGivenSimulator() {
        let args = IOSReduceMotion.writeArguments(udid: "OTHER", animationsEnabled: false)
        XCTAssertEqual(args[3], "OTHER")
    }
}
