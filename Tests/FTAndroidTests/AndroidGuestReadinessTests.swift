// guest の system_server 未起動印(AndroidGuestReadiness)の判定。
// witness: コールド起動直後(ブート/クイックブート復元直後)に settings/pm がスタックトレースで
// 失敗するが sys.boot_completed は既に 1 で使えない。

import XCTest
@testable import FTAndroid

final class AndroidGuestReadinessTests: XCTestCase {
    private let stackTrace = """
        java.lang.IllegalStateException: Cannot access system provider: 'settings' before system providers are installed!
        \tat android.provider.Settings$GlobalSettingsUri...
        \tat com.android.commands.settings.SettingsCmd.run(SettingsCmd.java:1)
        """

    func testJavaStackTraceReturnsIllegalStateExceptionLine() {
        XCTAssertEqual(
            AndroidGuestReadiness.systemServerStartingMarker(in: stackTrace),
            "java.lang.IllegalStateException: Cannot access system provider: 'settings' before system providers are installed!")
    }

    func testCantFindServiceReturnsThatLine() {
        XCTAssertEqual(
            AndroidGuestReadiness.systemServerStartingMarker(in: "cmd: Can't find service: package"),
            "cmd: Can't find service: package")
    }

    func testSuccessReturnsNil() {
        XCTAssertNil(AndroidGuestReadiness.systemServerStartingMarker(in: "Success"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(AndroidGuestReadiness.systemServerStartingMarker(in: ""))
    }

    func testVersionDowngradeReturnsNil() {
        XCTAssertNil(AndroidGuestReadiness.systemServerStartingMarker(
            in: "INSTALL_FAILED_VERSION_DOWNGRADE"))
    }

    func testUpdateIncompatibleReturnsNil() {
        XCTAssertNil(AndroidGuestReadiness.systemServerStartingMarker(
            in: "INSTALL_FAILED_UPDATE_INCOMPATIBLE"))
    }

    func testMultiLineOutputReturnsFirstMatchingLineTrimmed() {
        let output = "some unrelated line\n  cmd: Can't find service: package  \nmore output\n"
        XCTAssertEqual(
            AndroidGuestReadiness.systemServerStartingMarker(in: output),
            "cmd: Can't find service: package")
    }

    func testStillStartingMessageContainsSerialAndMarker() {
        let message = AndroidGuestReadiness.stillStartingMessage(
            marker: "cmd: Can't find service: package", serial: "emulator-5554")
        XCTAssertTrue(message.contains("emulator-5554"))
        XCTAssertTrue(message.contains("cmd: Can't find service: package"))
    }
}
