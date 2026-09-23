// 残骸ランナーの照合に**宛先のデバイス**を混ぜる判定(RunnerDestination)。
// これが無いと、同じポートに居る別デバイスの生きたランナーを「自分の残骸」として殺す
// (実地 2026-09-23: ブリッジを失った実機2台がどちらも既定ポート 8123 へ倒れ、殺し合った)。

import XCTest
@testable import FTBridgeClient

final class RunnerDestinationTests: XCTestCase {

    private let simCommand = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        + " test-without-building -xctestrun /repo/.fleetest/DerivedData/Build/Products/"
        + "FleetestRunner-8123.xctestrun -destination platform=iOS Simulator,"
        + "id=E38DCA93-95F2-4DDF-B1FE-29527205D3EE -resultBundlePath /repo/.fleetest/x.xcresult"
    private let deviceCommand = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        + " test-without-building -xctestrun /repo/.fleetest/DerivedData-device/Build/Products/"
        + "FleetestRunner-8123.xctestrun -destination platform=iOS,id=00008110-001460910E0A201E"

    func testReadsTheDestinationUDID() {
        XCTAssertEqual(RunnerDestination.udid(inCommand: simCommand),
                       "E38DCA93-95F2-4DDF-B1FE-29527205D3EE")
        XCTAssertEqual(RunnerDestination.udid(inCommand: deviceCommand),
                       "00008110-001460910E0A201E")
        XCTAssertNil(RunnerDestination.udid(inCommand: "xcodebuild test-without-building -xctestrun x"))
    }

    func testUDIDShapes() {
        XCTAssertTrue(RunnerDestination.isUDIDShaped("E38DCA93-95F2-4DDF-B1FE-29527205D3EE"))
        XCTAssertTrue(RunnerDestination.isUDIDShaped("00008110-001460910E0A201E"))
        // `bridge up --device "iPhone 17 Pro"` の名前指定は比較の材料にしない
        XCTAssertFalse(RunnerDestination.isUDIDShaped("iPhone 17 Pro"))
        XCTAssertFalse(RunnerDestination.isUDIDShaped("iPhone 17 Pro(iOS 27.0)-01"))
        XCTAssertFalse(RunnerDestination.isUDIDShaped(""))
    }

    /// **肯定的に別デバイスと読めた回だけ**残す
    func testLeavesOnlyPositivelyDifferentDevicesAlone() {
        XCTAssertEqual(
            RunnerDestination.belongsToOtherDevice(command: deviceCommand,
                                                   ourDevice: "00008110-000260242EEB801E"),
            "00008110-001460910E0A201E")
        // 自分の宛先(大文字小文字は問わない)は残骸として止めてよい
        XCTAssertNil(RunnerDestination.belongsToOtherDevice(
            command: simCommand, ourDevice: "e38dca93-95f2-4ddf-b1fe-29527205d3ee"))
        // 宛先が読めない・こちらが名前指定 → 従来どおり止める側へ倒す
        XCTAssertNil(RunnerDestination.belongsToOtherDevice(
            command: "xcodebuild test-without-building", ourDevice: "00008110-000260242EEB801E"))
        XCTAssertNil(RunnerDestination.belongsToOtherDevice(
            command: deviceCommand, ourDevice: "iPhone 17 Pro"))
    }
}
