import XCTest
@testable import FTCore

final class ScenarioQueueTests: XCTestCase {

    private func makeItem(id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp", platform: "android"))
    }

    func testRequeueAllowsUpToCapThenReturnsNil() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])

        let first = await queue.requeue(item)
        XCTAssertEqual(first, 1)
        let second = await queue.requeue(item)
        XCTAssertNil(second, "上限(1 回)を超えたら再キューしない")
    }

    func testRequeueAppendsItemToQueue() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])
        let empty = await queue.next()
        XCTAssertNil(empty)

        _ = await queue.requeue(item)
        let requeued = await queue.next()
        XCTAssertEqual(requeued?.info.id, "Foo.bar")
    }

    func testRequeueTracksAttemptsPerItemIndependently() async {
        let itemA = makeItem(id: "Foo.a")
        let itemB = makeItem(id: "Foo.b")
        let queue = ScenarioQueue([])

        _ = await queue.requeue(itemA)
        _ = await queue.requeue(itemA)
        let bFirst = await queue.requeue(itemB)
        XCTAssertEqual(bFirst, 1, "別シナリオの再試行回数は独立してカウントされる")
    }

    func testHasItemsFalseWhenEmpty() async {
        let queue = ScenarioQueue([])
        let hasItems = await queue.hasItems()
        XCTAssertFalse(hasItems)
    }

    func testHasItemsTrueThenFalseAfterDrain() async {
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([item])

        let hasItems = await queue.hasItems()
        XCTAssertTrue(hasItems)

        _ = await queue.next()
        let drained = await queue.hasItems()
        XCTAssertFalse(drained)
    }
}

/// 振り直しと記録の取り消しの順序(`RunOrchestrator.requeueDiscardingRecord`)。
/// **requeue が成立したときだけ**直前の記録を消す。上限到達の回は失敗記録がそのまま一次情報
/// (failedSteps / errorLogs / timeline)として残り、合成の skipped 記録で置き換えない。
/// 逆順(先に消してから requeue を聞く)だと、上限の回で最後の失敗の証拠が消える
final class RequeueRecordDiscardTests: XCTestCase {

    private func makeItem(id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp", platform: "android"))
    }

    private func makeRecorder() throws -> (RunRecorder, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-requeue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root),
                                         profile: "android", trigger: "test",
                                         captureHostMetrics: false)
        return (recorder, root)
    }

    private func recordFailure(_ recorder: RunRecorder, id: String, worker: String) {
        recorder.record(ScenarioRunRecord(
            scenarioID: id, title: id, platform: "android", worker: worker,
            passed: false, startedAt: "2026-09-06T00:00:00Z", durationMs: 1234,
            steps: StepCountsRecord(total: 3, passed: 2, failed: 1),
            failedSteps: [FailedStepRecord(index: 3, section: "expectation",
                                           description: "exist(#done)", command: "exist",
                                           failureKind: "notFound")],
            errorLogs: ["❌ exist(#done): not found"]))
    }

    /// 成立した振り直しでは従来どおり記録を消す(再実行の記録だけが残る)
    func testSuccessfulRequeueDiscardsTheFailedRecord() async throws {
        let (recorder, root) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])
        recordFailure(recorder, id: "Foo.bar", worker: "android:Pixel")

        let attempt = await RunOrchestrator.requeueDiscardingRecord(
            item, queue: queue, recorder: recorder, worker: "android:Pixel", discardRecord: true)

        XCTAssertEqual(attempt, 1)
        XCTAssertTrue(RunResultsStore.records(runDir: recorder.runDir).isEmpty,
                      "振り直した回の失敗記録は消える")
        let next = await queue.next()
        XCTAssertEqual(next?.info.id, "Foo.bar", "item はキューの末尾へ戻る")
    }

    /// 上限到達の回は**失敗記録に触らない**。合成の skipped 記録(total:1 skipped:1 durationMs:0)で
    /// 置き換えると failedSteps / errorLogs が失われ、run に残るのは「上限に達した」の1行だけになる
    func testRetryLimitKeepsTheFailedRecordAndWritesNoSyntheticSkip() async throws {
        let (recorder, root) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = makeItem(id: "Foo.bar")
        let queue = ScenarioQueue([])
        // 1回目: 振り直し成立(記録は消える)
        recordFailure(recorder, id: "Foo.bar", worker: "android:Pixel")
        let first = await RunOrchestrator.requeueDiscardingRecord(
            item, queue: queue, recorder: recorder, worker: "android:Pixel", discardRecord: true)
        XCTAssertEqual(first, 1)
        _ = await queue.next()
        // 2回目: 別の台でまた落ちた → 上限
        recordFailure(recorder, id: "Foo.bar", worker: "android:Pixel-02")

        let second = await RunOrchestrator.requeueDiscardingRecord(
            item, queue: queue, recorder: recorder, worker: "android:Pixel-02", discardRecord: true)

        XCTAssertNil(second, "上限(MAX_FREEZE_RETRIES)を超えたら requeue しない")
        let records = RunResultsStore.records(runDir: recorder.runDir)
        XCTAssertEqual(records.count, 1, "残るのは最後の失敗記録1件だけ(合成の skipped 記録を足さない)")
        guard let record = records.first else { return }
        XCTAssertEqual(record.worker, "android:Pixel-02")
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.failedSteps?.first?.command, "exist", "失敗ステップの事実が残る")
        XCTAssertEqual(record.errorLogs?.count, 1)
        XCTAssertEqual(record.durationMs, 1234)
        XCTAssertNil(record.skipKind)
        XCTAssertFalse(RunResultsQuery.isSkippedSynthetic(record),
                       "合成レコードの形(total:1 skipped:1 durationMs:0)になっていない")
        let hasItems = await queue.hasItems()
        XCTAssertFalse(hasItems)
    }

    /// プレフライト(まだ記録が無い)向けの discardRecord=false は記録を触らない
    func testDiscardRecordFalseLeavesRecordsAlone() async throws {
        let (recorder, root) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: root) }
        recordFailure(recorder, id: "Foo.bar", worker: "android:Pixel")

        let attempt = await RunOrchestrator.requeueDiscardingRecord(
            makeItem(id: "Foo.bar"), queue: ScenarioQueue([]), recorder: recorder,
            worker: "android:Pixel", discardRecord: false)

        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(RunResultsStore.records(runDir: recorder.runDir).count, 1)
    }

    /// **配線を守る**(ソース走査。WorkerStaggerWiringTests と同じ事情 —— RunOrchestrator は
    /// ドライバ・キュー・リースを要求するので単体で組めない): 上限到達の分岐が合成の skipped
    /// 記録や flowSkipped を出す形に戻らないこと、取り消しがヘルパー経由であること
    func testOrchestratorRetryLimitPathWritesNoSkippedRecord() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "private func discardAndRequeue("),
              let end = source[start.upperBound...].range(of: "\n    }\n") else {
            XCTFail("discardAndRequeue が見つからない"); return
        }
        let body = source[start.upperBound..<end.lowerBound]
        XCTAssertFalse(body.contains("recordSkipped("),
                       "上限到達で失敗記録を合成の skipped 記録に置き換えてはいけない")
        XCTAssertFalse(body.contains(".flowSkipped("),
                       "runOne が既に flowFinished を流している。flowSkipped を重ねない")
        XCTAssertFalse(body.contains("discardLast("),
                       "取り消しは requeueDiscardingRecord(requeue 成立後だけ消す)を通す")
        XCTAssertTrue(body.contains("requeueDiscardingRecord("))
        XCTAssertTrue(body.contains("\"retryLimit\""), "上限到達の事実は workerAnomalies に残す")
    }
}
