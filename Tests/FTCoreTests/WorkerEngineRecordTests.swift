import XCTest
@testable import FTCore

/// どのエンジンで走ったかの記録(シナリオの `engine`・run.json の `workerEngines`)とコンソールの文言
final class WorkerEngineRecordTests: XCTestCase {

    /// XCUITest は接続情報に engine が入らない(inapp / hybrid だけ入る)ので、iOS の nil は xcuitest と書く。Android は書かない
    func testRecordedEngineOfAConnection() {
        XCTAssertEqual(DriverConnection(platform: "ios", port: 8123, engine: "hybrid").recordedEngine, "hybrid")
        XCTAssertEqual(DriverConnection(platform: "ios", port: 8123, engine: nil).recordedEngine, "xcuitest")
        XCTAssertNil(DriverConnection(platform: "android", serial: "emulator-5554").recordedEngine)
    }

    /// 縮退した(頼んだものと違う)ときだけ理由を残す。頼んだものが分からなければ実効エンジンと同じとみなす
    func testFallbackReasonIsKeptOnlyWhenTheEngineDiffers() {
        let fellBack = WorkerEngineRecord.resolved(worker: "ios:iPhone 13(実機)", requested: "hybrid",
                                                   effective: "xcuitest", fallbackReason: "not in this machine's keychain")
        XCTAssertEqual(fellBack.reason, "not in this machine's keychain")
        let same = WorkerEngineRecord.resolved(worker: "ios:SE3", requested: "hybrid", effective: "hybrid",
                                               fallbackReason: "stale")
        XCTAssertNil(same.reason)
        let unknown = WorkerEngineRecord.resolved(worker: "ios:sim", requested: nil, effective: "xcuitest", fallbackReason: nil)
        XCTAssertEqual(unknown.requested, "xcuitest")
    }

    func testSummaryNamesEveryDeviceAndWarnsOnFallback() {
        let lines = WorkerEngineSummary.lines([
            WorkerEngineRecord(worker: "ios:SE3", requested: "hybrid", effective: "hybrid", reason: nil),
            WorkerEngineRecord(worker: "ios:iPhone 13(実機)", requested: "hybrid", effective: "xcuitest",
                               reason: "in-app injection is not available (x)"),
        ])
        XCTAssertEqual(lines, [
            "🔧 Engines: SE3 hybrid, iPhone 13(実機) xcuitest",
            "⚠️ iPhone 13(実機): ran on xcuitest instead of hybrid — in-app injection is not available (x)",
        ])
        XCTAssertEqual(WorkerEngineSummary.lines([]), [])
    }

    /// 見出しのラベル("<名前>(ios:<port>)")から記録を引く。デバイス名に括弧があっても末尾の括弧群だけを落とす
    func testEngineIsFoundFromTheWorkerLabel() {
        let records = [WorkerEngineRecord(worker: "ios:iPhone 13(実機)", requested: "hybrid", effective: "hybrid", reason: nil)]
        XCTAssertEqual(WorkerEngineSummary.engine(forLabel: "iPhone 13(実機)(ios:8134)", in: records), "hybrid")
        XCTAssertNil(WorkerEngineSummary.engine(forLabel: "Pixel(android:emulator-5554)", in: records))
        XCTAssertNil(WorkerEngineSummary.engine(forLabel: "SE3(ios:8123)", in: records))
    }

    /// **型では守れない継ぎ目**(どちらも既定値のある引数・任意の呼び出しを通る。外すと run.json の記録が黙って欠ける):
    /// ①オーケストレータはワーカーの参加(初期・遅延参加の両方が通る admit)で記録器へ渡す
    /// ②iOS のワーカーは供給の「頼んだエンジン・縮退の理由」を持つ
    func testEngineRecordingIsWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let orchestrator = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"),
                                      encoding: .utf8).components(separatedBy: "\n")
        let admit = try XCTUnwrap(orchestrator.firstIndex { $0.contains("func admit(_ worker: RunWorker") })
        XCTAssertTrue(orchestrator[admit...].prefix(4).contains { $0.contains("recorder?.recordWorkerEngine(engine)") },
                      "admit がワーカーの実効エンジンを記録していない")
        XCTAssertEqual(orchestrator.filter { $0.contains("recorder?.recordWorkerEngine(engine)") }.count, 2,
                       "参加(admit)と起こし直しの両方で記録していない")
        let factory = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(factory.contains("requestedEngine: device.requestedEngine, engineFallbackReason: device.engineFallbackReason"),
                      "iOS のワーカーが頼んだエンジンと縮退の理由を受け取っていない")
    }

    /// 欄は古い記録に無い(nil = 不明)。書いた値が読み戻せること
    func testRecordsRoundTripTheNewFields() throws {
        let builder = ScenarioRecordBuilder(scenarioID: "T.S0010", platform: "ios", title: nil, worker: "ios:SE3",
                                            engine: "hybrid")
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        let decoded = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.engine, "hybrid")
        let old = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(
            ScenarioRunRecord(scenarioID: "T.S0010", platform: "ios", passed: true, startedAt: "x", durationMs: 1,
                              steps: StepCountsRecord())))
        XCTAssertNil(old.engine)
        let meta = RunMetaRecord(runID: "r", project: "p", profile: nil, host: "h", trigger: "cli", startedAt: "s",
                                 workerEngines: [WorkerEngineRecord(worker: "ios:SE3", requested: "hybrid",
                                                                    effective: "hybrid", reason: nil)])
        let metaDecoded = try JSONDecoder().decode(RunMetaRecord.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(metaDecoded.workerEngines?.first?.effective, "hybrid")
    }
}
