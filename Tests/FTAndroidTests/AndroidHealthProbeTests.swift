// AndroidHealthProbe の純粋パーサ(wifiDisabled/clockSkewed)と AndroidHealthDebounce の検証。
// adb 実行を伴う observeIssues は対象外(ネットワーク/実機依存のため)。

import XCTest
@testable import FTAndroid

final class AndroidHealthProbeTests: XCTestCase {

    // MARK: - wifiDisabled

    func testWifiDisabledDetectsMultilineOutput() {
        let output = "Wifi is disabled\nWifi scan mode is enabled\n"
        XCTAssertTrue(AndroidHealthProbe.wifiDisabled(statusOutput: output))
    }

    func testWifiEnabledIsNotDisabled() {
        let output = "Wifi is enabled\nWifi is connected to \"AndroidWifi\"\n"
        XCTAssertFalse(AndroidHealthProbe.wifiDisabled(statusOutput: output))
    }

    func testEmptyWifiOutputIsNotDisabled() {
        XCTAssertFalse(AndroidHealthProbe.wifiDisabled(statusOutput: ""))
    }

    // MARK: - clockSkewed

    func testClockWithinThresholdIsNotSkewed() {
        let host: TimeInterval = 1_753_600_000
        let guestOutput = "\(Int(host) + 5)"
        XCTAssertEqual(
            AndroidHealthProbe.clockSkewed(
                dateOutput: guestOutput, hostNow: host,
                thresholdSeconds: AndroidHealthProbe.clockSkewThresholdSeconds),
            false)
    }

    func testClockTwoHoursOffIsSkewed() {
        let host: TimeInterval = 1_753_600_000
        let guestOutput = "\(Int(host) + 2 * 3600)"
        XCTAssertEqual(
            AndroidHealthProbe.clockSkewed(
                dateOutput: guestOutput, hostNow: host,
                thresholdSeconds: AndroidHealthProbe.clockSkewThresholdSeconds),
            true)
    }

    func testClockOutputWithWhitespaceAndNewlineIsParsed() {
        let host: TimeInterval = 1_753_600_000
        let guestOutput = "  \(Int(host))  \n"
        XCTAssertEqual(
            AndroidHealthProbe.clockSkewed(
                dateOutput: guestOutput, hostNow: host, thresholdSeconds: 120),
            false)
    }

    func testNonNumericClockOutputIsUnknown() {
        XCTAssertNil(
            AndroidHealthProbe.clockSkewed(
                dateOutput: "date: not found", hostNow: 1_753_600_000, thresholdSeconds: 120))
    }

    // MARK: - AndroidHealthDebounce

    func testFirstObservationDoesNotConfirm() {
        var debounce = AndroidHealthDebounce(confirmThreshold: 2)
        let confirmed = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        XCTAssertEqual(confirmed, [])
    }

    func testTwoConsecutiveObservationsConfirm() {
        var debounce = AndroidHealthDebounce(confirmThreshold: 2)
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        let confirmed = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        XCTAssertEqual(confirmed, [AndroidHealthProbe.issueWifiDisabled])
    }

    func testSingleCleanObservationClearsImmediately() {
        var debounce = AndroidHealthDebounce(confirmThreshold: 2)
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        let confirmed = debounce.record([], serial: "emulator-5554")
        XCTAssertEqual(confirmed, [])
        XCTAssertEqual(debounce.confirmed(serial: "emulator-5554"), [])
    }

    func testSwitchingIssuesKeepsStreaksIndependent() {
        var debounce = AndroidHealthDebounce(confirmThreshold: 2)
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        // wifi の記憶は observed に含まれない時点で即クリア、clock は 1 回目なのでまだ未確定
        let afterSwitch = debounce.record([AndroidHealthProbe.issueClockSkew], serial: "emulator-5554")
        XCTAssertEqual(afterSwitch, [])
        // clock が2回連続してようやく確定(wifi のカウンタとは独立)
        let confirmed = debounce.record([AndroidHealthProbe.issueClockSkew], serial: "emulator-5554")
        XCTAssertEqual(confirmed, [AndroidHealthProbe.issueClockSkew])
    }

    func testForgetClearsSerial() {
        var debounce = AndroidHealthDebounce(confirmThreshold: 2)
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        _ = debounce.record([AndroidHealthProbe.issueWifiDisabled], serial: "emulator-5554")
        XCTAssertEqual(debounce.confirmed(serial: "emulator-5554"), [AndroidHealthProbe.issueWifiDisabled])
        debounce.forget(serial: "emulator-5554")
        XCTAssertEqual(debounce.confirmed(serial: "emulator-5554"), [])
    }
}
