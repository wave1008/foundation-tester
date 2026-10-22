import XCTest
@testable import FTCore

/// どのモードで走ったかの記録(シナリオの `mode`・run.json の `workerModes`)とコンソールの文言
final class WorkerModeRecordTests: XCTestCase {

    /// XCUITest は接続情報に mode が入らない(inapp だけ入る)ので、iOS の nil は xcuitest と書く。Android は書かない
    func testRecordedModeOfAConnection() {
        XCTAssertEqual(DriverConnection(platform: "ios", port: 8123, mode: "inapp").recordedMode, "inapp")
        XCTAssertEqual(DriverConnection(platform: "ios", port: 8123, mode: nil).recordedMode, "xcuitest")
        XCTAssertNil(DriverConnection(platform: "android", serial: "emulator-5554").recordedMode)
    }

    /// 縮退した(頼んだものと違う)ときだけ理由を残す。頼んだものが分からなければ実効モードと同じとみなす
    func testFallbackReasonIsKeptOnlyWhenTheModeDiffers() {
        let fellBack = WorkerModeRecord.resolved(worker: "ios:iPhone 13(実機)", requested: "inapp",
                                                   effective: "xcuitest", fallbackReason: "not in this machine's keychain")
        XCTAssertEqual(fellBack.reason, "not in this machine's keychain")
        let same = WorkerModeRecord.resolved(worker: "ios:SE3", requested: "inapp", effective: "inapp",
                                               fallbackReason: "stale")
        XCTAssertNil(same.reason)
        let unknown = WorkerModeRecord.resolved(worker: "ios:sim", requested: nil, effective: "xcuitest", fallbackReason: nil)
        XCTAssertEqual(unknown.requested, "xcuitest")
    }

    func testSummaryNamesEveryDeviceAndWarnsOnFallback() {
        let lines = WorkerModeSummary.lines([
            WorkerModeRecord(worker: "ios:SE3", requested: "inapp", effective: "inapp", reason: nil),
            WorkerModeRecord(worker: "ios:iPhone 13(実機)", requested: "inapp", effective: "xcuitest",
                               reason: "in-app injection is not available (x)"),
        ])
        XCTAssertEqual(lines, [
            "🔧 Modes: SE3 inapp, iPhone 13(実機) xcuitest",
            "⚠️ iPhone 13(実機): ran in xcuitest mode instead of inapp mode — in-app injection is not available (x)",
        ])
        XCTAssertEqual(WorkerModeSummary.lines([]), [])
    }

    /// 見出しのラベル("<名前>(ios:<port>)")から記録を引く。デバイス名に括弧があっても末尾の括弧群だけを落とす
    func testModeIsFoundFromTheWorkerLabel() {
        let records = [WorkerModeRecord(worker: "ios:iPhone 13(実機)", requested: "inapp", effective: "inapp", reason: nil)]
        XCTAssertEqual(WorkerModeSummary.mode(forLabel: "iPhone 13(実機)(ios:8134)", in: records), "inapp")
        XCTAssertNil(WorkerModeSummary.mode(forLabel: "Pixel(android:emulator-5554)", in: records))
        XCTAssertNil(WorkerModeSummary.mode(forLabel: "SE3(ios:8123)", in: records))
    }

    /// **型では守れない継ぎ目**(どちらも既定値のある引数・任意の呼び出しを通る。外すと run.json の記録が黙って欠ける):
    /// ①オーケストレータはワーカーの参加(初期・遅延参加の両方が通る admit)で記録器へ渡す
    /// ②iOS のワーカーは供給の「頼んだモード・縮退の理由」を持つ
    func testModeRecordingIsWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let orchestrator = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"),
                                      encoding: .utf8).components(separatedBy: "\n")
        let admit = try XCTUnwrap(orchestrator.firstIndex { $0.contains("func admit(_ worker: RunWorker") })
        XCTAssertTrue(orchestrator[admit...].prefix(4).contains { $0.contains("recorder?.recordWorkerMode(record)") },
                      "admit がワーカーの実効モードを記録していない")
        XCTAssertEqual(orchestrator.filter { $0.contains("recorder?.recordWorkerMode(record)") }.count, 2,
                       "参加(admit)と起こし直しの両方で記録していない")
        let factory = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(factory.contains("requestedMode: device.requestedMode, modeFallbackReason: device.modeFallbackReason"),
                      "iOS のワーカーが頼んだモードと縮退の理由を受け取っていない")
    }

    /// 欄は古い記録に無い(nil = 不明)。書いた値が読み戻せること
    func testRecordsRoundTripTheNewFields() throws {
        let builder = ScenarioRecordBuilder(scenarioID: "T.S0010", platform: "ios", title: nil, worker: "ios:SE3",
                                            mode: "inapp")
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        let decoded = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.mode, "inapp")
        let old = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(
            ScenarioRunRecord(scenarioID: "T.S0010", platform: "ios", passed: true, startedAt: "x", durationMs: 1,
                              steps: StepCountsRecord())))
        XCTAssertNil(old.mode)
        let meta = RunMetaRecord(runID: "r", project: "p", profile: nil, host: "h", trigger: "cli", startedAt: "s",
                                 workerModes: [WorkerModeRecord(worker: "ios:SE3", requested: "inapp",
                                                                    effective: "inapp", reason: nil)])
        let metaDecoded = try JSONDecoder().decode(RunMetaRecord.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(metaDecoded.workerModes?.first?.effective, "inapp")
    }
}
