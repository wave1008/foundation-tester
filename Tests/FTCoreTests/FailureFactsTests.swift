// 「どこで落ちたか」を結果 JSON から**機械可読に**読めることの固定。
//
// 受け手の運用: 落ちた run を「条件フェーズ(共有フローや端末の準備)」と「検証フェーズ
// (テスト内容)」に仕分ける。前者は再実行・後者はシナリオ修正で**対応が正反対**なので、
// Markdown レポートを人が読まないと決められない状態は毎回のコストになる。
//
// **ここで固定するのは事実の運搬だけ**。「環境要因の失敗か」という分類はツールが持たない
// (アプリが重いのかマシンが混んでいるのかは区別できない。推測を混ぜると誤った緑・赤を作る)。

import XCTest
@testable import FTCore

/// 呼ばれない前提のドライバ(このテストは worker の識別子だけを見る)
private struct QuietDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class FailureFactsTests: XCTestCase {

    // MARK: - 失敗ステップの素性が results/ まで運ばれるか

    func testFailedStepCarriesPhaseCommandKindAndNotes() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "ios",
                                            title: nil, worker: nil)
        builder.consume(stepEvent(index: 1, status: "passed", section: "condition",
                                  command: "launchApp"))
        var failure = stepEvent(index: 2, status: "failed", section: "condition",
                                command: "tap")
        failure.detail = "cannot resolve the locator: id=nav_input"
        failure.failureKind = StepFailureKind.notFound.rawValue
        failure.notes = [StepNote.interruptionDismissed.rawValue]
        builder.consume(failure)

        let record = builder.build(passed: false, timedOut: false, startedAt: Date(),
                                   durationMs: 1, packageRoot: nil)

        XCTAssertEqual(record.failedSteps?.count, 1, "落ちたステップだけが載る")
        guard let step = record.failedSteps?.first else {
            XCTFail("失敗ステップが記録されていない"); return
        }
        XCTAssertEqual(step.section, "condition")
        XCTAssertEqual(step.command, "tap")
        XCTAssertEqual(step.failureKind, "not-found")
        XCTAssertEqual(step.notes, ["interruption-dismissed"])
        XCTAssertEqual(step.detail, "cannot resolve the locator: id=nav_input")
    }

    /// 注記が無いステップに空配列を書かない(旧レコードと同じ形を保つ)
    func testFailedStepWithoutNotesOmitsTheKey() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "ios",
                                            title: nil, worker: nil)
        var failure = stepEvent(index: 1, status: "failed", section: "expectation",
                                command: "textIs")
        failure.notes = []
        builder.consume(failure)

        let record = builder.build(passed: false, timedOut: false, startedAt: Date(),
                                   durationMs: 1, packageRoot: nil)

        XCTAssertNil(record.failedSteps?.first?.notes)
    }

    /// 新しい欄を持たない過去の results/ が読めること(後発 Optional の契約)
    func testLegacyFailedStepStillDecodes() throws {
        let json = """
        {"index":3,"description":"tap \\"#a\\"","section":"action"}
        """
        let step = try JSONDecoder().decode(FailedStepRecord.self, from: Data(json.utf8))
        XCTAssertEqual(step.section, "action")
        XCTAssertNil(step.command)
        XCTAssertNil(step.failureKind)
        XCTAssertNil(step.notes)
    }

    // MARK: - 素性の仕分け(推測しない)

    /// **エラーの型だけ**で仕分ける。文言一致で分けると、文言を直した瞬間に静かに壊れる
    func testThrownErrorsAreClassifiedByType() {
        XCTAssertEqual(StepExecutor.failureKind(thrown: DriverError.bridgeUnreachable("x")),
                       .driverUnreachable)
        XCTAssertEqual(StepExecutor.failureKind(thrown: DriverError.bridgeConnectionRefused("x")),
                       .driverUnreachable)
        XCTAssertEqual(StepExecutor.failureKind(thrown: DriverError.badResponse(status: 500, body: "x")),
                       .driverError)
    }

    /// **知らない型は nil**(「その他」に丸めない = 読み手が「言えていない」と分かる)
    func testUnknownErrorsAreNotGuessed() {
        struct Unknown: Error {}
        XCTAssertNil(StepExecutor.failureKind(thrown: Unknown()))
        XCTAssertNil(StepExecutor.failureKind(thrown: URLError(.timedOut)))
    }

    /// rawValue は results/ に永続化されるので固定(変えると過去の run と比較できなくなる)
    func testRawValuesArePersistedIdentifiers() {
        XCTAssertEqual(StepFailureKind.selectorSyntax.rawValue, "selector-syntax")
        XCTAssertEqual(StepFailureKind.notFound.rawValue, "not-found")
        XCTAssertEqual(StepFailureKind.assertion.rawValue, "assertion")
        XCTAssertEqual(StepFailureKind.driverUnreachable.rawValue, "driver-unreachable")
        XCTAssertEqual(StepFailureKind.driverError.rawValue, "driver-error")
        XCTAssertEqual(StepFailureKind.timeout.rawValue, "timeout")
        XCTAssertEqual(StepFailureKind.appNotInstalled.rawValue, "app-not-installed")
    }

    // MARK: - ワーカー異常(run.json)

    /// prose(degradedWorkers)と構造化(workerAnomalies)は**同じ事象を同時に**持つ。
    /// 構造化側の worker はシナリオ記録の worker と同じ規則 = join できる
    func testWorkerAnomalyJoinsScenarioRecordsByWorkerID() {
        let worker = RunWorker(label: "Pixel 9(Android 15)-02(android:emulator-5556)",
                               platform: "android", driver: QuietDriver(),
                               connection: DriverConnection(platform: "android", physical: false),
                               logicalName: "Pixel 9(Android 15)-02")

        XCTAssertEqual(RunOrchestrator.workerID(worker), "android:Pixel 9(Android 15)-02")
    }

    /// 論理名を持たない経路(--ports 等)では worker を作らない(label だけで照合させる)
    func testWorkerIDIsNilWithoutALogicalName() {
        let worker = RunWorker(label: "ios:8100", platform: "ios", driver: QuietDriver(),
                               connection: DriverConnection(platform: "ios", physical: false), logicalName: nil)

        XCTAssertNil(RunOrchestrator.workerID(worker))
    }

    /// **run.json まで実際に書かれる**こと(prose と構造化を同時に持つ)。
    /// 一時ディレクトリに書く = 並列テストが既定のパスで競合しないため
    func testRecorderWritesWorkerAnomaliesIntoRunJSON() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-anomaly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "SampleApp",
                                  rootURL: root.appendingPathComponent("TestProjects/SampleApp"))
        let recorder = RunRecorder.begin(project: project, profile: "android", trigger: "test",
                                         captureHostMetrics: false)

        recorder.finish(total: 1, passed: 1, failed: 0,
                        degradedWorkers: ["Pixel(android:emulator-5556): dropped out"],
                        workerAnomalies: [WorkerAnomalyRecord(
                            kind: "degraded", worker: "android:Pixel",
                            label: "Pixel(android:emulator-5556)", reason: "dropped out")])

        let runDir = RunResultsStore.runDir(
            resultsDir: RunResultsStore.resultsDir(projectRoot: project.rootURL),
            runID: recorder.runID)
        let data = try Data(contentsOf: runDir.appendingPathComponent("run.json"))
        let meta = try JSONDecoder().decode(RunMetaRecord.self, from: data)

        XCTAssertEqual(meta.workerAnomalies?.count, 1)
        XCTAssertEqual(meta.workerAnomalies?.first?.kind, "degraded")
        XCTAssertEqual(meta.workerAnomalies?.first?.worker, "android:Pixel",
                       "scenarios/*.json の worker と join できる形で書かれること")
        XCTAssertEqual(meta.degradedWorkers?.count, 1, "表示用の1行も従来どおり残る")
    }

    /// 異常が無い run には欄を書かない(旧レコードと同じ形 = 「異常なし」を欄の不在で表せる)
    func testQuietRunOmitsTheAnomalyKey() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-anomaly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "SampleApp",
                                  rootURL: root.appendingPathComponent("TestProjects/SampleApp"))
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)

        recorder.finish(total: 1, passed: 1, failed: 0)

        let runDir = RunResultsStore.runDir(
            resultsDir: RunResultsStore.resultsDir(projectRoot: project.rootURL),
            runID: recorder.runID)
        let text = try String(contentsOf: runDir.appendingPathComponent("run.json"),
                              encoding: .utf8)
        XCTAssertFalse(text.contains("workerAnomalies"))
    }

    // MARK: -

    private func stepEvent(index: Int, status: String, section: String?,
                           command: String?) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.index = index
        event.description = "step \(index)"
        event.status = status
        event.section = section
        event.command = command
        return event
    }
}
