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

/// 「端末が答えない」の断り文は、何が起きなかったかを呼び手が渡す(ブリッジ起動の文がドライバの断りに出ていた)
extension AndroidGuestReadinessTests {
    func testNoAnswerMessageCarriesTheCallersConsequence() {
        XCTAssertEqual(AndroidGuestReadiness.noAnswerMessage(serial: "emulator-5554", seconds: 15, consequence: "nothing was sent to it"),
                       "emulator-5554 did not answer `adb shell` within 15s (the device may be frozen or still booting;"
                       + " `adb devices` can still list it) — nothing was sent to it. If it stays this way, restart the device")
    }

    func testOnlyTheBridgeColdStartSaysTheBridgeWasNotStarted() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid")
        let driver = try String(contentsOf: dir.appendingPathComponent("AndroidDriver.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: dir.appendingPathComponent("AndroidBridge.swift"), encoding: .utf8)
        XCTAssertFalse(driver.contains("the bridge was not started"), "ドライバの断りにブリッジ起動の文がある")
        XCTAssertTrue(bridge.contains(#"consequence: "the bridge was not started""#))
        let gate = try XCTUnwrap(driver.range(of: "func requireDeviceAnswers() throws {"))
        XCTAssertTrue(driver[gate.upperBound...].prefix(300).contains(#"consequence: "nothing was sent to it""#),
                      "入口の門が「何も送っていない」と言っていない")
    }
}
