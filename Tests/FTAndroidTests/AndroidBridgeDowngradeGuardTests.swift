// installBridgeIfNeeded が adb install を試みる前の fail-fast 判定(AndroidDriver.downgradeRefusal)。
// Android は versionCode の引き下げインストールを拒否するため、より新しいブリッジが載った台に
// 古い ftester が古い APK を当てると INSTALL_FAILED_VERSION_DOWNGRADE か無応答になる
// (2026-08-14 にフリート8台が全滅した実害。docs/remote-runner.md §18.5)。

import XCTest
@testable import FTAndroid

final class AndroidBridgeDowngradeGuardTests: XCTestCase {

    func testInstalledNewerThanExpectedReturnsRefusalWithBothVersionsAndPackageAndAdvice() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61)
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("62"), text)
        XCTAssertTrue(text.contains("61"), text)
        XCTAssertTrue(text.contains(AndroidDriver.bridgePackage), text)
        XCTAssertTrue(text.contains("uninstall"), text)
        XCTAssertTrue(text.contains("update"), text)
    }

    func testInstalledEqualToExpectedReturnsNil() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: 61, expected: 61))
    }

    func testInstalledOlderThanExpectedReturnsNilSoTheNormalUpgradePathStaysOpen() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: 60, expected: 61))
    }

    func testNotInstalledReturnsNilSoTheNormalInstallPathStaysOpen() {
        XCTAssertNil(AndroidDriver.downgradeRefusal(installed: nil, expected: 61))
    }

    func testUninstallCommandIncludesSerialWhenGiven() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61, serial: "emulator-5554")
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("adb -s emulator-5554 uninstall \(AndroidDriver.bridgePackage)"), text)
    }

    func testUninstallCommandOmitsSerialFlagWhenNil() {
        let text = AndroidDriver.downgradeRefusal(installed: 62, expected: 61, serial: nil)
        guard let text else { return XCTFail("installed > expected で nil が返った") }
        XCTAssertTrue(text.contains("adb uninstall \(AndroidDriver.bridgePackage)"), text)
        XCTAssertFalse(text.contains("-s "), text)
    }
}
