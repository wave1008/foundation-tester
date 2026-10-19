// AndroidHealthProbe の純粋パーサ(wifiDisabled/clockSkewed)と AndroidHealthDebounce の検証。
// adb 実行を伴う observeIssues は対象外(ネットワーク/実機依存のため)。

import XCTest
@testable import FTAndroid

final class AndroidHealthProbeTests: XCTestCase {

    // MARK: - hostRoute

    /// `ip route get 10.0.2.2` の終了コード: 0 = 経路あり / 2 = 経路なし(実測)/ それ以外・取れない = 不明(何も撃たない)
    func testHostRouteReadsOnlyTheTwoKnownExitCodes() {
        XCTAssertEqual(AndroidHealthProbe.hostRoute(exitStatus: 0), .reachable)
        XCTAssertEqual(AndroidHealthProbe.hostRoute(exitStatus: 2), .unreachable)
        XCTAssertEqual(AndroidHealthProbe.hostRoute(exitStatus: 1), .unknown)
        XCTAssertEqual(AndroidHealthProbe.hostRoute(exitStatus: 255), .unknown, "adb 自身の失敗を経路なしと読まない")
        XCTAssertEqual(AndroidHealthProbe.hostRoute(exitStatus: nil), .unknown)
    }

    /// 起動直後の「経路なし」は待てば消える(実測 boot_completed + 5.6 秒)。出たら即返し、出なければ上限で確定する
    func testAwaitHostRouteWaitsOutTheBootWindow() async {
        var answers: [AndroidHealthProbe.HostRoute] = [.unreachable, .unreachable, .reachable, .unreachable]
        var clock = Date(timeIntervalSince1970: 0)
        var probes = 0
        let settled = await AndroidHealthProbe.awaitHostRoute(
            settleSeconds: 60, probe: { probes += 1; return answers.removeFirst() },
            sleep: { clock += $0 }, now: { clock })
        XCTAssertEqual(settled, .reachable)
        XCTAssertEqual(probes, 3)

        clock = Date(timeIntervalSince1970: 0)
        probes = 0
        let broken = await AndroidHealthProbe.awaitHostRoute(
            settleSeconds: 60, probe: { probes += 1; return .unreachable },
            sleep: { clock += $0 }, now: { clock })
        XCTAssertEqual(broken, .unreachable, "上限まで出なければ届かないと確定する")
        XCTAssertEqual(probes, 61)

        probes = 0
        answers = [.unreachable, .unknown, .reachable]
        let unknown = await AndroidHealthProbe.awaitHostRoute(
            settleSeconds: 60, probe: { probes += 1; return answers.removeFirst() },
            sleep: { clock += $0 }, now: { clock })
        XCTAssertEqual(unknown, .unknown, "adb が答えなくなったら待たずに不明を返す(何も撃たない)")
        XCTAssertEqual(probes, 2)
    }

    func testHostRouteSettleSecondsIsPinned() {
        XCTAssertEqual(AndroidHealthProbe.hostRouteSettleSeconds, 60)
    }

    /// run 前の点検は素の 1 回の読みで「経路なし」を確定しない(起動直後の台を停止と起動 → 除外していた)
    func testPreRunNetworkTriageWaitsForTheRoute() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("AndroidHealthProbe.hostRoute(serial:"))
        XCTAssertEqual(source.components(separatedBy: "AndroidHealthProbe.awaitHostRoute(serial:").count - 1, 2)
    }

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

    // MARK: - blankScreen

    func testBlankScreenDetectsUniformFrameSize() {
        // 実測: ウェッジ時の一様白フレーム 10,295 バイト(@1080x2424)
        XCTAssertTrue(AndroidHealthProbe.blankScreen(pngByteCount: 10_295))
    }

    func testNormalScreenIsNotBlank() {
        // 実測: 正常画面 130KB 以上
        XCTAssertFalse(AndroidHealthProbe.blankScreen(pngByteCount: 132_927))
    }

    func testEmptyCaptureIsNotJudged() {
        XCTAssertFalse(AndroidHealthProbe.blankScreen(pngByteCount: 0))
    }

    // MARK: - renderMode

    func testGpuGlesLineDetectsGpu() {
        let output = "GLES: Google (Apple), Android Emulator OpenGL ES Translator (Apple M2 Ultra), " +
            "OpenGL ES 3.0 (4.1 Metal - 91.7)"
        XCTAssertEqual(AndroidHealthProbe.renderMode(fromSurfaceFlinger: output), "gpu")
    }

    func testSwiftShaderGlesLineDetectsCpu() {
        let output = "GLES: Google, Android Emulator OpenGL ES Translator, OpenGL ES 3.0 (SwiftShader)"
        XCTAssertEqual(AndroidHealthProbe.renderMode(fromSurfaceFlinger: output), "cpu")
    }

    func testNoGlesLineIsUnknown() {
        XCTAssertNil(AndroidHealthProbe.renderMode(fromSurfaceFlinger: "some other dumpsys output\n"))
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
