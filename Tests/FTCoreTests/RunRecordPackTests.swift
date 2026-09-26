import XCTest
@testable import FTCore

/// `RunResultsStore.scanRunsAndRecords` の run 単位パック(`RunRecordPack`)。
/// scanFingerprint と同じ stat 判定(runStat)を経由するので、テストの完了/進行中の作り方は
/// RunResultsStoreTests の markRunCompleted/markRunInProgress と同じ手順を使う。
final class RunRecordPackTests: XCTestCase {
    var repoRoot: URL!
    var project: TestProject!
    var resultsDir: URL!
    var packCacheDir: URL!
    let executableKey = "exe=1000.0:100"

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunRecordPackTests-\(UUID().uuidString)")
        project = TestProject(name: "SampleApp", rootURL: repoRoot.appendingPathComponent("TestProjects/SampleApp"))
        resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        packCacheDir = RunRecordPack.cacheDir(stateDir: project.stateDir)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeMeta(runID: String, startedAt: String) -> RunMetaRecord {
        RunMetaRecord(runID: runID, project: "SampleApp", profile: nil,
                     host: "testmachine", trigger: "cli", startedAt: startedAt)
    }

    private func makeScenarioRecord(scenarioID: String, runID: String, durationMs: Int = 100,
                                    startedAt: String = "2026-01-01T00:00:00Z",
                                    timeline: [TimelineStepRecord]? = nil) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, platform: "ios", worker: nil, host: "testmachine",
            passed: true, startedAt: startedAt, durationMs: durationMs,
            steps: StepCountsRecord(total: 1, passed: 1, failed: 0), timeline: timeline)
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// run.json を十分未来にする(RunResultsStoreTests と同じ手順) —— 以後 scenarios/ に何を
    /// 書いてもこのテスト内では「完了」の判定を保つ
    private func markRunCompleted(_ runDir: URL) throws {
        try setModificationDate(Date().addingTimeInterval(3600), at: runDir.appendingPathComponent("run.json"))
    }

    private func markRunInProgress(_ runDir: URL) throws {
        try setModificationDate(Date(timeIntervalSince1970: 0), at: runDir.appendingPathComponent("run.json"))
    }

    /// entries だけ見るテスト用の短縮呼び出し
    private func scan(since: Date? = nil, key: String? = nil) -> [RunResultsStore.ScannedRecord] {
        scanBoth(since: since, key: key).entries
    }

    private func scanBoth(since: Date? = nil,
                          key: String? = nil) -> (runs: [RunMetaRecord], entries: [RunResultsStore.ScannedRecord]) {
        RunResultsStore.scanRunsAndRecords(resultsDir: resultsDir, since: since,
                                           packCacheDir: packCacheDir, executableKey: key ?? executableKey)
    }

    // MARK: - 完了 run はパックされ、2回目はパックから読む

    func testCompletedRunIsPackedThenReadFromThePackOnTheNextScan() throws {
        let runID = "20260101-000000Z-mach-0001"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)

        let first = scan()
        XCTAssertEqual(first.map(\.record.scenarioID), ["Foo.a"])
        let packURL = RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.path), "completed run must be packed")

        // 元ファイルを in-place(rename 無し)で書き換える —— scenarios/ ディレクトリ自身の
        // mtime は動かないので runStatKey は変わらず、2回目はパックの中身(古い durationMs)を
        // 返すはず(= 実際にパックから読んでいることの証拠)
        let scenarioFile = runDir.appendingPathComponent("scenarios/Foo.a.json")
        let edited = try JSONEncoder().encode(makeScenarioRecord(scenarioID: "Foo.a", runID: runID, durationMs: 999))
        try edited.write(to: scenarioFile) // options 無し = in-place 上書き(rename しない)

        let second = scan()
        XCTAssertEqual(second.first?.record.durationMs, 100,
                       "second scan must come from the pack, not the edited file")
    }

    // MARK: - run.json もパックされる

    /// run.json の変更が(サイズ・mtime のどちらかが必ず動くので)常にパックを無効化することは
    /// `testPackIsInvalidatedWhenRunJSONChanges` が確かめる。ここではパックの中身自体が
    /// run.json の decode 結果と一致することと、変更しない限り2回目も同じ値を返すことを見る
    func testMetaIsPackedAndMatchesTheSourceRunJSON() throws {
        let runID = "20260101-000000Z-mach-0012"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)

        let firstRuns = scanBoth().runs
        XCTAssertEqual(firstRuns.map(\.runID), [runID])

        let data = try Data(contentsOf: RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir))
        let pack = try JSONDecoder().decode(RunRecordPack.Contents.self, from: data)
        XCTAssertEqual(pack.meta?.runID, runID)
        XCTAssertEqual(pack.meta?.startedAt, "2026-01-01T00:00:00Z")

        let secondRuns = scanBoth().runs
        XCTAssertEqual(secondRuns.map(\.runID), [runID])
        XCTAssertEqual(secondRuns.first?.startedAt, "2026-01-01T00:00:00Z")
    }

    // MARK: - 進行中の run はパックしない

    func testInProgressRunIsNotPacked() throws {
        let runID = "20260101-000000Z-mach-0002"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        try markRunInProgress(runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")

        let (runs, entries) = scanBoth()
        XCTAssertEqual(entries.map(\.record.scenarioID), ["Foo.a"], "in-progress run is still read directly")
        XCTAssertEqual(runs.map(\.runID), [runID])
        let packURL = RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packURL.path), "in-progress run must not be packed")
    }

    // MARK: - 無効化

    func testPackIsInvalidatedWhenANewScenarioIsAdded() throws {
        let runID = "20260101-000000Z-mach-0003"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)
        XCTAssertEqual(scan().map(\.record.scenarioID), ["Foo.a"])

        // scenarios/ へエントリを追加(rename を伴う atomic 書き)= ディレクトリ自身の mtime が動く
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.b", runID: runID), runDir: runDir, fileName: "Foo.b")
        try markRunCompleted(runDir) // run.json を再び scenarios/ より新しくする(完了のまま保つ)

        XCTAssertEqual(scan().map(\.record.scenarioID).sorted(), ["Foo.a", "Foo.b"],
                       "the new scenario must be visible once the run's stat changes")
    }

    /// run.json だけが書き変わっても(finish() の再上書き相当)無効化される
    func testPackIsInvalidatedWhenRunJSONChanges() throws {
        let runID = "20260101-000000Z-mach-0011"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)
        _ = scan()

        // scenarios/ は変えず run.json だけ書き直す(finish() の追記相当。サイズが変わる)
        var finished = makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z")
        finished.finishedAt = "2026-01-01T00:05:00Z"
        RunResultsStore.writeMeta(finished, runDir: runDir)
        try markRunCompleted(runDir)

        let scenarioFile = runDir.appendingPathComponent("scenarios/Foo.a.json")
        let edited = try JSONEncoder().encode(makeScenarioRecord(scenarioID: "Foo.a", runID: runID, durationMs: 777))
        try edited.write(to: scenarioFile)

        let (runs, entries) = scanBoth()
        XCTAssertEqual(entries.first?.record.durationMs, 777,
                       "run.json changing alone must invalidate the pack even though scenarios/ did not")
        XCTAssertEqual(runs.first?.finishedAt, "2026-01-01T00:05:00Z")
    }

    func testPackIsInvalidatedWhenTheExecutableKeyDiffers() throws {
        let runID = "20260101-000000Z-mach-0004"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)
        _ = scan(key: "exe=1000.0:100")

        let scenarioFile = runDir.appendingPathComponent("scenarios/Foo.a.json")
        let edited = try JSONEncoder().encode(makeScenarioRecord(scenarioID: "Foo.a", runID: runID, durationMs: 999))
        try edited.write(to: scenarioFile)

        let readWithDifferentExecutable = scan(key: "exe=2000.0:200")
        XCTAssertEqual(readWithDifferentExecutable.first?.record.durationMs, 999,
                       "a different executable fingerprint must miss the old pack and re-decode")
    }

    // MARK: - 掃除

    func testOrphanPackIsRemovedWhenItsRunDirectoryDisappears() throws {
        let keptID = "20260101-000000Z-mach-0005"
        let goneID = "20260101-010000Z-mach-0006"
        for runID in [keptID, goneID] {
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
            RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
            RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
            try markRunCompleted(runDir)
        }
        _ = scan()
        let goneRunDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: goneID)
        let keptRunDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: keptID)
        let goneURL = RunRecordPack.url(cacheDir: packCacheDir, runDir: goneRunDir)
        let keptURL = RunRecordPack.url(cacheDir: packCacheDir, runDir: keptRunDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goneURL.path))

        try FileManager.default.removeItem(at: goneRunDir)
        _ = scan() // 掃除は scanRunsAndRecords のついでに走る

        XCTAssertFalse(FileManager.default.fileExists(atPath: goneURL.path), "the orphaned pack must be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path), "unrelated packs must survive")
    }

    func testOrphanPackMonthIsRemovedWhenTheWholeMonthIsPruned() throws {
        let runID = "20260101-000000Z-mach-0007"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)
        _ = scan()
        let packMonthDir = packCacheDir.appendingPathComponent("2026-01")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packMonthDir.path))

        // `git rm -r <project>/results/runs/2026-01` を模す(docs/results-json.md §git での扱い)
        try FileManager.default.removeItem(at: resultsDir.appendingPathComponent("runs/2026-01"))
        _ = scan()

        XCTAssertFalse(FileManager.default.fileExists(atPath: packMonthDir.path),
                       "a pruned month must not leave its pack directory behind")
    }

    // MARK: - 壊れたパックは黙って直接読みへ倒す

    func testCorruptPackFallsBackToDirectRead() throws {
        let runID = "20260101-000000Z-mach-0008"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)
        _ = scan()

        let packURL = RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir)
        try Data("not json".utf8).write(to: packURL)

        let result = scan()
        XCTAssertEqual(result.map(\.record.scenarioID), ["Foo.a"], "a corrupt pack must not lose the run's records")
    }

    // MARK: - パック経由と直接読みの一致(集計に効く欄だけ)

    /// timeline は縮小されるので丸ごとの等値は取らない —— **集計(insights)の結果が同じ**ことを見る。
    /// 実データ3プロジェクトでの一致確認は別途 `--no-cache` の出力比較で行う(このテストは
    /// ユニットレベルで同じ性質を固定する)
    func testPackedAndDirectReadsProduceTheSameAggregationResult() throws {
        let runID = "20260101-000000Z-mach-0009"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        let timeline = [
            TimelineStepRecord(index: 0, description: "tap", status: "passed"),
            TimelineStepRecord(index: 1, description: "wait", status: "passed", durationMs: 1234,
                               notes: [StepNote.settleCapped.rawValue]),
        ]
        RunResultsStore.writeScenario(
            makeScenarioRecord(scenarioID: "Foo.a", runID: runID, timeline: timeline),
            runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)

        let direct = RunResultsStore.scanRecordEntries(resultsDir: resultsDir).map(\.record)
        // 1回目はまだパックが無いので直接デコード(= 縮小前の記録がそのまま返る)
        let firstPass = scan().map(\.record)
        // 2回目からはパック経由(= 縮小済みの記録が返る)
        let packed = scan().map(\.record)
        let packedAgain = scan().map(\.record)

        for candidates in [firstPass, packed, packedAgain] {
            XCTAssertEqual(RunResultsQuery.insights(records: direct, runs: []).count,
                           RunResultsQuery.insights(records: candidates, runs: []).count,
                           "aggregation must not change once timeline is trimmed for storage")
        }
        // 縮小の中身も確認: notes 付きステップだけ・4欄だけに縮む(パック経由の読みだけ縮む)
        let trimmedTimeline = try XCTUnwrap(packed.first?.timeline)
        XCTAssertEqual(trimmedTimeline.count, 1)
        XCTAssertEqual(trimmedTimeline.first?.notes, [StepNote.settleCapped.rawValue])
        XCTAssertNil(trimmedTimeline.first?.durationMs, "kept steps must drop timing fields")
        XCTAssertEqual(packedAgain.first?.timeline?.count, 1, "the pack keeps returning the trimmed shape")
        XCTAssertEqual(direct.first?.timeline?.count, 2, "sanity: the source record itself keeps both steps")
    }

    // MARK: - 読み飛ばし件数もパックへ残す

    func testSkipCountsSurviveThroughThePack() throws {
        let runID = "20260101-000000Z-mach-0010"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        var future = makeScenarioRecord(scenarioID: "Foo.b", runID: runID)
        future.schemaVersion = RunRecordSchema.current + 1
        RunResultsStore.writeScenario(future, runDir: runDir, fileName: "Foo.b")
        try Data("not json".utf8).write(to: runDir.appendingPathComponent("scenarios/Foo.c.json"))
        try markRunCompleted(runDir)

        XCTAssertEqual(scan().map(\.record.scenarioID), ["Foo.a"])
        let data = try Data(contentsOf: RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir))
        let pack = try JSONDecoder().decode(RunRecordPack.Contents.self, from: data)
        XCTAssertEqual(pack.decodeFailureCount, 1)
        XCTAssertEqual(pack.schemaTooNewCount, 1)
        XCTAssertEqual(pack.entries.map(\.record.scenarioID), ["Foo.a"])
        XCTAssertNotNil(pack.meta)
        XCTAssertNil(pack.metaSkipReason)
    }

    /// run.json が壊れている run のメタ読み飛ばし理由もパックへ残る
    func testMetaSkipReasonSurvivesThroughThePack() throws {
        let runID = "20260101-000000Z-mach-0013"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: runDir.appendingPathComponent("run.json"))
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "Foo.a", runID: runID), runDir: runDir, fileName: "Foo.a")
        try markRunCompleted(runDir)

        let (runs, entries) = scanBoth()
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(entries.map(\.record.scenarioID), ["Foo.a"])

        let data = try Data(contentsOf: RunRecordPack.url(cacheDir: packCacheDir, runDir: runDir))
        let pack = try JSONDecoder().decode(RunRecordPack.Contents.self, from: data)
        XCTAssertNil(pack.meta)
        XCTAssertEqual(pack.metaSkipReason, .decodeFailure)

        // 2回目もパック経由で同じ結果になる(run.json を直接読み直さない)
        XCTAssertTrue(scanBoth().runs.isEmpty)
    }
}
