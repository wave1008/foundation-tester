import XCTest
@testable import FTCore

/// `RunResultsStore.scanRunsAndRecords(memo:)` のメモリの控え(`RunRecordMemo`。MCP の ft_results)。
/// 完了/進行中の作り方は RunRecordPackTests と同じ(run.json の mtime を scenarios/ より後にする = 完了)
final class RunRecordMemoTests: XCTestCase {
    var repoRoot: URL!
    var resultsDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunRecordMemoTests-\(UUID().uuidString)")
        resultsDir = repoRoot.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func record(_ scenarioID: String, runID: String, durationMs: Int = 100) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, platform: "ios", worker: nil, host: "testmachine",
            passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: durationMs,
            steps: StepCountsRecord(total: 1, passed: 1, failed: 0))
    }

    @discardableResult
    private func makeRun(_ runID: String, in resultsDir: URL, completed: Bool = true) throws -> URL {
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(RunMetaRecord(runID: runID, project: "SampleApp", profile: nil, host: "testmachine",
                                                trigger: "cli", startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        let date = completed ? Date().addingTimeInterval(3600) : Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: runDir.appendingPathComponent("run.json").path)
        RunResultsStore.writeScenario(record("Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        return runDir
    }

    /// 元ファイルを rename 無しで書き換える = run の stat は変わらない。2回目はメモの値(元の 100)が返れば、メモから読んでいる
    private func editInPlace(_ runDir: URL, runID: String) throws {
        let data = try JSONEncoder().encode(record("Foo.a", runID: runID, durationMs: 999))
        try data.write(to: runDir.appendingPathComponent("scenarios/Foo.a.json"))
    }

    private func scan(_ memo: RunRecordMemo?, resultsDir: URL? = nil) -> (runs: [RunMetaRecord], entries: [RunResultsStore.ScannedRecord]) {
        RunResultsStore.scanRunsAndRecords(resultsDir: resultsDir ?? self.resultsDir, memo: memo)
    }

    func testCompletedRunIsReadFromTheMemoOnTheNextScan() throws {
        let runID = "20260101-000000Z-mach-0001"
        let runDir = try makeRun(runID, in: resultsDir)
        let memo = RunRecordMemo()

        let first = scan(memo)
        XCTAssertEqual(first.runs.map(\.runID), [runID])
        XCTAssertEqual(first.entries.map(\.record.durationMs), [100])
        try editInPlace(runDir, runID: runID)

        let second = scan(memo)
        XCTAssertEqual(second.runs.map(\.runID), [runID])
        XCTAssertEqual(second.entries.map(\.record.durationMs), [100], "second scan must come from the memo")
        XCTAssertEqual(second.entries.map(\.url), first.entries.map(\.url))
        // メモを渡さない走査は書き換えた元ファイルを読む(上の 100 が古い値であることの対照)
        XCTAssertEqual(scan(nil).entries.map(\.record.durationMs), [999])
    }

    func testInProgressRunIsNotRemembered() throws {
        let runID = "20260101-000000Z-mach-0002"
        let runDir = try makeRun(runID, in: resultsDir, completed: false)
        let memo = RunRecordMemo()

        _ = scan(memo)
        XCTAssertEqual(memo.count(resultsDir: resultsDir), 0)
        try editInPlace(runDir, runID: runID)
        XCTAssertEqual(scan(memo).entries.map(\.record.durationMs), [999], "in-progress run is always read directly")
    }

    func testChangedRunStatIsReadAgain() throws {
        let runID = "20260101-000000Z-mach-0003"
        let runDir = try makeRun(runID, in: resultsDir)
        let memo = RunRecordMemo()
        _ = scan(memo)

        // 記録を足す = scenarios/ の mtime が動く(run.json はまだ未来なので完了のまま)
        RunResultsStore.writeScenario(record("Foo.b", runID: runID), runDir: runDir, fileName: "Foo.b")
        XCTAssertEqual(scan(memo).entries.map(\.record.scenarioID), ["Foo.a", "Foo.b"])
    }

    func testRunsThatDisappearAreDropped() throws {
        let kept = try makeRun("20260101-000000Z-mach-0004", in: resultsDir)
        let removed = try makeRun("20260101-000000Z-mach-0005", in: resultsDir)
        let memo = RunRecordMemo()
        _ = scan(memo)
        XCTAssertEqual(memo.count(resultsDir: resultsDir), 2)

        try FileManager.default.removeItem(at: removed)
        XCTAssertEqual(scan(memo).runs.map(\.runID), [kept.lastPathComponent])
        XCTAssertEqual(memo.count(resultsDir: resultsDir), 1)
    }

    /// プロジェクトごとに分けて持つ(別プロジェクトの走査で手放さない)
    func testEachResultsDirIsKeptSeparately() throws {
        let otherResults = repoRoot.appendingPathComponent("other-results")
        try makeRun("20260101-000000Z-mach-0006", in: resultsDir)
        try makeRun("20260101-000000Z-mach-0007", in: otherResults)
        let memo = RunRecordMemo()

        _ = scan(memo)
        _ = scan(memo, resultsDir: otherResults)
        XCTAssertEqual(memo.count(resultsDir: resultsDir), 1)
        XCTAssertEqual(memo.count(resultsDir: otherResults), 1)
    }
}
