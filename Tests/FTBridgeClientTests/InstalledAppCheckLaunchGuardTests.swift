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
                verdict: .installed, isAndroid: false, engine: "xcuitest", bundleID: bundleID),
            .allow)
    }

    func testNotInstalledRefusesRegardlessOfEngine() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: false, engine: "xcuitest", bundleID: bundleID),
            .refuse(.notInstalled))
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: true, engine: nil, bundleID: bundleID),
            .refuse(.notInstalled))
    }

    /// unknown × xcuitest/hybrid/エンジン不明は断つ(XCUIApplication.launch() を経由しうる危険側)
    func testUnknownRefusesOnXCUITestLikeEngines() {
        for engine in ["xcuitest", "hybrid", nil] {
            XCTAssertEqual(
                InstalledAppCheck.launchGuard(
                    verdict: .unknown("adb"), isAndroid: false, engine: engine, bundleID: bundleID),
                .refuse(.unknown("adb")),
                "engine: \(String(describing: engine))")
        }
    }

    /// unknown × in-app / unknown × Android は素通す(ランナーを道連れにしない経路)
    func testUnknownAllowsOnInAppOrAndroid() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .unknown("simctl unavailable"), isAndroid: false, engine: "inapp",
                bundleID: bundleID),
            .allow)
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .unknown("adb"), isAndroid: true, engine: "xcuitest", bundleID: bundleID),
            .allow)
    }

    /// springboard は verdict によらず門の外
    func testSpringboardBypassesTheGate() {
        XCTAssertEqual(
            InstalledAppCheck.launchGuard(
                verdict: .notInstalled, isAndroid: false, engine: "xcuitest",
                bundleID: "com.apple.springboard"),
            .allow)
    }
}
