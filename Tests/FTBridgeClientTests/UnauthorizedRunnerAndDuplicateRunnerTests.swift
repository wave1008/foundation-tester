import XCTest
@testable import FTBridgeClient

/// 承認なしで始まったスイート(ready を名乗るが UI 操作は全部断られる)と、同じ実機への2本目のランナー。
/// ログ行は 2026-09-24 に iPhone 15 Pro(iOS 26.6.2)で採ったもの
final class UnauthorizedRunnerAndDuplicateRunnerTests: XCTestCase {
    private let unauthorized = "2026-09-24 05:29:09.235876+0900 FleetestRunnerUITests-Runner[25039:9101634]"
        + " [fleetest] XCTest issue not recorded (the bridge keeps running): Failed to get screenshot:"
        + " Not authorized for performing UI testing actions.\r\n"
    private let suiteStarted = "Test Suite 'All tests' started at 2026-09-24 05:27:51.001\r\n"

    func testNotAuthorizedAfterSuiteStartIsARunnerFailureNamingTheApproval() throws {
        let reason = try XCTUnwrap(IOSDeviceTransport.runnerFailureReason(inLog: suiteStarted + unauthorized))
        XCTAssertTrue(reason.contains("was not approved"), reason)
        XCTAssertTrue(reason.contains("Not authorized for performing UI testing actions"), reason)
    }

    func testSuiteStartAloneIsNotAFailure() {
        XCTAssertNil(IOSDeviceTransport.runnerFailureReason(inLog: suiteStarted))
    }

    private let ps = """
      62405 /Applications/Xcode_27.app/Contents/Developer/usr/bin/xcodebuild test-without-building -xctestrun /Users/x/.fleetest/DerivedData-device/Build/Products/FleetestRunner-8136.xctestrun -destination platform=iOS,id=00008110-001460910E0A201E -resultBundlePath /tmp/a
      63120 /Applications/Xcode_27.app/Contents/Developer/usr/bin/xcodebuild test-without-building -xctestrun /Users/x/.fleetest/DerivedData-device/Build/Products/FleetestRunner-8137.xctestrun -destination platform=iOS,id=00008110-001460910E0A201E -resultBundlePath /tmp/b
      63121 /opt/homebrew/bin/iproxy 8137 8137 -u 00008110-001460910E0A201E
      55764 /Applications/Xcode_27.app/Contents/Developer/usr/bin/xcodebuild test-without-building -xctestrun /Users/x/.fleetest/DerivedData/Build/Products/FleetestRunner-8125.xctestrun -destination platform=iOS Simulator,id=E1A517B3-2E0A-45AD-9C32-38AF315F39F7 -resultBundlePath /tmp/c
    """

    func testFindsTheOtherRunnerOfTheSameDeviceOnly() {
        let found = BridgeLauncher.runnersOnDevice(
            psOutput: ps, device: "00008110-001460910E0A201E", excludingPort: 8137)
        XCTAssertEqual(found.map(\.port), [8136])
        XCTAssertEqual(found.map(\.pid), [62405])
    }

    func testOwnPortAndOtherDevicesAreNotCounted() {
        XCTAssertEqual(BridgeLauncher.runnersOnDevice(
            psOutput: ps, device: "00008130-001819863E60001C", excludingPort: 8150).count, 0)
        let both = BridgeLauncher.runnersOnDevice(
            psOutput: ps, device: "00008110-001460910E0A201E", excludingPort: 9999)
        XCTAssertEqual(Set(both.map(\.port)), [8136, 8137])
    }
}
