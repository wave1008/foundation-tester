// 計測 run の識別を finish より前に run.json へ書く(殺された run の run.json にも識別が残る)。

import XCTest
@testable import FTCore

final class RunRecorderResponseMeasurementTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-rm-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecorder() -> RunRecorder {
        RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "android", trigger: "test",
                          captureHostMetrics: false, runGroup: "grp")
    }

    private let info = ResponseMeasurementRunInfo(deviceName: "Pixel-4a", serial: "SER1", model: "Pixel 4a",
                                                  osVersion: "13", repeatCount: 3)

    func testIdentityIsWrittenBeforeFinishAndKeepsTheRunningFields() {
        let recorder = makeRecorder()
        XCTAssertNil(RunResultsStore.meta(runDir: recorder.runDir)?.responseMeasurement)
        recorder.recordResponseMeasurement(info)
        let meta = RunResultsStore.meta(runDir: recorder.runDir)
        XCTAssertEqual(meta?.responseMeasurement, info)
        XCTAssertNil(meta?.finishedAt, "実行中の形のまま")
        XCTAssertEqual(meta?.pid, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(meta?.runGroup, "grp")
        XCTAssertEqual(meta?.profile, "android")
    }

    func testNilKeepsTheRunJsonAsBegan() {
        let recorder = makeRecorder()
        let before = RunResultsStore.meta(runDir: recorder.runDir)
        recorder.recordResponseMeasurement(nil)
        XCTAssertEqual(RunResultsStore.meta(runDir: recorder.runDir)?.runID, before?.runID)
        XCTAssertNil(RunResultsStore.meta(runDir: recorder.runDir)?.responseMeasurement)
    }

    /// 供給失敗の経路は識別を持たず finish(responseMeasurement: nil) を呼ぶ。先に書いた識別を消さない
    func testFinishWithoutIdentityKeepsTheRecordedOne() {
        let recorder = makeRecorder()
        recorder.recordResponseMeasurement(info)
        recorder.finish(total: 1, passed: 0, failed: 1, performanceMode: false,
                        fmSettings: FMSettingsRecord(heal: false, fmTextVisibilityCheck: false,
                                                      screenLooksLike: false, ocrTextVisibilityCheck: false),
                        setOverrides: nil, servicesWarnings: [], responseMeasurement: nil)
        let meta = RunResultsStore.meta(runDir: recorder.runDir)
        XCTAssertNotNil(meta?.finishedAt)
        XCTAssertEqual(meta?.responseMeasurement, info)
    }
}
