// iOS 実機の計測で xctrace を録るかの判定・引数・残骸の判定、`downTimeMs` の写し。

import XCTest
@testable import FTCore

final class ResponseTracePolicyTests: XCTestCase {

    private func profile(measuring: Bool, devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "r", appName: "app", apps: [:], devices: devices, fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true,
            enableAnimations: measuring, responseMeasurement: measuring, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    private func device(_ platform: String, physical: Bool, udid: String? = "UDID-1") -> ResolvedDevice {
        ResolvedDevice(platform: platform, spec: DeviceSpec(
            name: "d", kind: physical ? .physical : .virtual, udid: udid, serial: platform == "android" ? "S" : nil))
    }

    func testRecordsOnlyForMeasuringPhysicalIOS() {
        XCTAssertEqual(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("ios", physical: true)]))?.udid, "UDID-1")
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: false, devices: [device("ios", physical: true)])))
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("android", physical: true)])),
            "Android は最初のフレームをブリッジが返す")
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("ios", physical: false)])))
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("ios", physical: true, udid: nil)])))
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("ios", physical: true, udid: "")])))
        XCTAssertNil(ResponseTracePolicy.recordingDevice(
            resolved: profile(measuring: true, devices: [device("ios", physical: true), device("ios", physical: true)])))
    }

    func testRecordArgumentsPinTheVerifiedCommand() {
        XCTAssertEqual(ResponseTracePolicy.recordArguments(udid: "U", output: "/t/run.trace"), [
            "xcrun", "xctrace", "record", "--device", "U", "--instrument", "Display", "--attach", "backboardd",
            "--time-limit", "2h", "--output", "/t/run.trace",
        ])
    }

    func testExportArguments() {
        XCTAssertEqual(ResponseTracePolicy.exportTableArguments(trace: "/t", schema: "time-info", output: "/o.xml"), [
            "xcrun", "xctrace", "export", "--input", "/t",
            "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-info\"]", "--output", "/o.xml",
        ])
        XCTAssertEqual(ResponseTracePolicy.exportTocArguments(trace: "/t", output: "/o.xml"),
                       ["xcrun", "xctrace", "export", "--input", "/t", "--toc", "--output", "/o.xml"])
    }

    func testStopLimitGrowsWithTheRecording() {
        XCTAssertEqual(ResponseTracePolicy.stopLimitSeconds(recordedSeconds: 0), 60)
        XCTAssertEqual(ResponseTracePolicy.stopLimitSeconds(recordedSeconds: 400), 160)
        XCTAssertEqual(ResponseTracePolicy.stopLimitSeconds(recordedSeconds: -5), 60)
    }

    func testStaleWorkDirDecision() {
        let name = ResponseTracePolicy.workDirPrefix + "X"
        XCTAssertTrue(ResponseTracePolicy.isStale(name: name, ownerPID: 1, ownerAlive: false, ageSeconds: 0))
        XCTAssertFalse(ResponseTracePolicy.isStale(name: name, ownerPID: 1, ownerAlive: true, ageSeconds: 1e9))
        XCTAssertFalse(ResponseTracePolicy.isStale(name: name, ownerPID: nil, ownerAlive: false, ageSeconds: 10),
                       "持ち主の書き出し前の一瞬は消さない")
        XCTAssertTrue(ResponseTracePolicy.isStale(name: name, ownerPID: nil, ownerAlive: false, ageSeconds: 61))
        XCTAssertFalse(ResponseTracePolicy.isStale(name: "other-dir", ownerPID: 1, ownerAlive: false, ageSeconds: 1e9))
    }

    func testMakeCopiesDownTimeMsOnAllCollectedPaths() {
        let quiet = ResponsePrepareResult(quiet: true, waitedMs: 1)
        let withFrame = ResponseMeasurementRecord.make(
            prepare: quiet, collect: ResponseCollectResult(downTimeMs: 777, firstFrameDelayMs: 30))
        XCTAssertEqual(withFrame.downTimeMs, 777)
        // iOS: 最初のフレームはランナーが返さない(nil)。注入の時刻だけが入る
        let iosShape = ResponseMeasurementRecord.make(
            prepare: quiet, collect: ResponseCollectResult(downTimeMs: 888, firstFrameDelayMs: nil))
        XCTAssertEqual(iosShape.downTimeMs, 888)
        XCTAssertNil(iosShape.firstFrameMs)
        XCTAssertNil(iosShape.firstFrameMissing)
        let noInput = ResponseMeasurementRecord.make(
            prepare: quiet, collect: ResponseCollectResult(downTimeMs: nil, firstFrameDelayMs: nil, reason: "noInjectedInput"))
        XCTAssertNil(noInput.downTimeMs)
        XCTAssertNil(ResponseMeasurementRecord.make(prepare: quiet, collect: nil).downTimeMs)
    }

    func testDownTimeMsRoundTrips() throws {
        let record = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 1, firstFrameMs: nil,
                                               firstFrameMissing: nil, downTimeMs: 123_456)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ResponseMeasurementRecord.self, from: data), record)
    }
}
