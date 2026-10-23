// 起動待ちの打ち切り理由(BridgeLauncher.startupAbort)の順序の固定。bind できないランナーはテストが即座に
// 終わり xcodebuild も抜けるので、終了の判定が先だと portInUse に届かず撃ち直しの手当てが走らない
// (実測 iPhone SE3 のログの末尾: bindFailed(48) → TEST EXECUTE SUCCEEDED → プロセス終了)。

import XCTest
@testable import FTBridgeClient

final class BridgeLauncherStartupAbortTests: XCTestCase {

    private let boundFailedLog = """
        [fleetest] XCTest issue not recorded (the bridge keeps running): failed: caught error: "bindFailed(48)"
        Test Case '-[FleetestRunnerUITests.FleetestBridgeTests testRunBridgeServer]' passed (0.022 seconds).
        ** TEST EXECUTE SUCCEEDED **
        """

    func testBindFailureWinsOverTheExitedRunner() {
        XCTAssertEqual(BridgeLauncher.startupAbort(logText: boundFailedLog, runnerAlive: false), .portInUse)
    }

    func testBindFailureWinsOverTheEndedSession() {
        XCTAssertEqual(BridgeLauncher.startupAbort(logText: boundFailedLog + "\nTesting failed:", runnerAlive: true),
                       .portInUse)
    }

    func testOtherEndingsKeepTheirReasons() {
        XCTAssertEqual(BridgeLauncher.startupAbort(logText: "** TEST EXECUTE FAILED **", runnerAlive: true),
                       .sessionEnded("** TEST EXECUTE FAILED **"))
        XCTAssertEqual(BridgeLauncher.startupAbort(logText: "Testing started", runnerAlive: false), .runnerExited)
        XCTAssertNil(BridgeLauncher.startupAbort(logText: "Testing started", runnerAlive: true))
        XCTAssertNil(BridgeLauncher.startupAbort(logText: nil, runnerAlive: nil), "pid が分からないうちは待つ")
    }
}
