// InstalledAppCheck.launchGuard の固定。ft_launch(MCP)と api live serve の launch/activate
// (ライブ操作パネル)が共有する唯一の判定元 —— 未インストールのまま
// XCUIApplication.launch() を撃つとランナーが約60秒でハングして自壊する(実地 L2)。

import XCTest
@testable import FTBridgeClient

final class InstalledAppCheckLaunchGuardTests: XCTestCase {

    private let bundleID = "com.example.myapp"

    func testInstalledAlwaysAllows() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .installed, isAndroid: false, bridge: "xcuitest", bundleID: bundleID),
            .allow)
    }

    func testNotInstalledRefusesRegardlessOfBridge() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: false, bridge: "xcuitest", bundleID: bundleID),
            .refuse(.notInstalled))
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: true, bridge: nil, bundleID: bundleID),
            .refuse(.notInstalled))
    }

    /// unknown × xcuitest/ブリッジ不明は断つ(XCUIApplication.launch() を経由しうる危険側)
    func testUnknownRefusesOnXCUITestLikeBridges() {
        for bridge in ["xcuitest", nil] {
            XCTAssertEqual(
                InstalledAppCheck.launchGuard(
                    verdict: .unknown("adb"), isAndroid: false, bridge: bridge, bundleID: bundleID),
                .refuse(.unknown("adb")),
                "bridge: \(String(describing: bridge))")
        }
    }

    /// unknown × in-app / unknown × Android は素通す(ランナーを道連れにしない経路)
    func testUnknownAllowsOnInAppOrAndroid() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .unknown("simctl unavailable"), isAndroid: false, bridge: "inapp",
                bundleID: bundleID),
            .allow)
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .unknown("adb"), isAndroid: true, bridge: "xcuitest", bundleID: bundleID),
            .allow)
    }

    /// springboard は verdict によらず門の外
    func testSpringboardBypassesTheGate() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: false, bridge: "xcuitest",
                bundleID: "com.apple.springboard"),
            .allow)
    }
}
