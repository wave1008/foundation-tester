import XCTest
@testable import FTCore

final class RunResultsStoreTests: XCTestCase {
    var repoRoot: URL!
    var project: TestProject!
    var resultsDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunResultsStoreTests-\(UUID().uuidString)")
        project = TestProject(name: "SampleApp", rootURL: repoRoot.appendingPathComponent("TestProjects/SampleApp"))
        resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeMeta(runID: String, startedAt: String, schemaVersion: Int = RunRecordSchema.current) -> RunMetaRecord {
        RunMetaRecord(
            schemaVersion: schemaVersion, runID: runID, project: "SampleApp", profile: nil,
            host: "testmachine", trigger: "cli", startedAt: startedAt)
    }

    private func makeScenarioRecord(scenarioID: String, runID: String, passed: Bool = true,
                                    worker: String? = nil) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, platform: "ios", worker: worker, host: "testmachine",
            passed: passed, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
            steps: StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1))
    }

    // MARK: - パス導出

    func testResultsDirAndRunDir() {
        XCTAssertEqual(resultsDir, project.rootURL.appendingPathComponent("results"))
        let runID = "20260315-120000Z-mach-abcd"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        XCTAssertEqual(runDir, resultsDir.appendingPathComponent("runs/2026-03/\(runID)"))
    }

    // MARK: - 書き込み→読み取りの往復

    func testWriteAndScanRoundTrip() {
        let runID = "20260101-000000Z-mach-0001"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: "2026-01-01T00:00:00Z"), runDir: runDir)
        let record = makeScenarioRecord(scenarioID: "Foo.bar", runID: runID)
        let written = RunResultsStore.writeScenario(record, runDir: runDir, fileName: "Foo.bar")
        XCTAssertNotNil(written)

        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir)
        XCTAssertEqual(runs.map(\.runID), [runID])

        let records = RunResultsStore.scanRecords(resultsDir: resultsDir)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].scenarioID, "Foo.bar")
        XCTAssertEqual(records[0].runID, runID)
    }

    /// countingPlatform を指定すると、maxRuns の枠は「その platform のレコードを含む run」だけで
    /// 数える(混在 results/ で対象 platform の実績が窓から押し出されるのを防ぐ)。
    func testMaxRunsCountsOnlyRunsWithTheGivenPlatform() {
        // 新しい ios の run を2件、古い android の run を1件
        for (i, platform) in ["ios", "ios", "android"].enumerated() {
            let runID = String(format: "2026010%d-000000Z-mach-100%d", 3 - i, i)
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
            var record = makeScenarioRecord(scenarioID: "S\(i)", runID: runID)
            record.platform = platform
            RunResultsStore.writeScenario(record, runDir: runDir, fileName: "S\(i)")
        }

        // platform 非対応の数え方だと新しい ios 2件で枠が尽き、android は読めない
        let blind = RunResultsStore.scanRecords(resultsDir: resultsDir, maxRuns: 2)
        XCTAssertFalse(blind.contains { $0.platform == "android" },
                       "従来の数え方では android が窓の外(この前提が崩れたらテストの意味が無い)")

        let aware = RunResultsStore.scanRecords(resultsDir: resultsDir, maxRuns: 2,
                                                countingPlatform: "android")
        XCTAssertTrue(aware.contains { $0.platform == "android" },
                      "android の実績を含む run を2件ぶん探すので窓に入る")
    }

    // MARK: - 観測数で数える窓(LPT の実績読み込み)

    /// 記録を1件書く(runID は新しいほど辞書順で大きい = 走査順の「新しい方」)
    private func write(scenario: String, runID: String, platform: String = "ios",
                       durationMs: Int = 100) {
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        var record = makeScenarioRecord(scenarioID: scenario, runID: runID)
        record.platform = platform
        record.durationMs = durationMs
        RunResultsStore.writeScenario(record, runDir: runDir, fileName: scenario)
    }

    /// **今日の実害そのもの**: 1シナリオだけの run を数本挟むと、run 数で数える窓は
    /// それだけで埋まり、直前のフル run の実績が丸ごと消える(2026-08-11 のフル E2E で
    /// iOS 側が軒並み `1/N with history` に落ちた)。観測数で数えれば残る
    func testSingleScenarioRunsDoNotEvictTheFullRunHistory() {
        // 古い方にフル run(A/B/C)、新しい方に「A だけ」の run を5本
        for s in ["A", "B", "C"] { write(scenario: s, runID: "20260101-000000Z-mach-0001") }
        for i in 1...5 { write(scenario: "A", runID: String(format: "202601%02d-000000Z-mach-900%d", i + 1, i)) }

        let byRuns = RunResultsStore.scanRecords(resultsDir: resultsDir, maxRuns: 5,
                                                 countingPlatform: "ios")
        XCTAssertFalse(byRuns.contains { $0.scenarioID == "B" },
                       "run 数で数えると B は窓の外(この前提が崩れたらテストの意味が無い)")

        let byObservations = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                        maxObservationsPerScenario: 5)
        XCTAssertTrue(byObservations.contains { $0.scenarioID == "B" },
                      "B の観測が5件に満たないので、遡ってフル run まで読むこと")
        XCTAssertTrue(byObservations.contains { $0.scenarioID == "C" })
    }

    /// 上限は**シナリオごと**に効く(1本ばかり読み続けない)
    func testObservationsAreCappedPerScenario() {
        for i in 1...9 { write(scenario: "A", runID: String(format: "202601%02d-000000Z-mach-800%d", i, i)) }
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                  maxObservationsPerScenario: 3)
        XCTAssertEqual(records.filter { $0.scenarioID == "A" }.count, 3)
    }

    /// **新しい方から**採る(古い実績で中央値を作らない)
    func testObservationsComeFromTheNewestRuns() {
        write(scenario: "A", runID: "20260101-000000Z-mach-0001", durationMs: 1000)
        write(scenario: "A", runID: "20260102-000000Z-mach-0002", durationMs: 2000)
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                  maxObservationsPerScenario: 1)
        XCTAssertEqual(records.map(\.durationMs), [2000])
    }

    /// platform ごとに別々に数える(混在プロジェクトで片方に窓を食われない)
    func testObservationsAreCountedPerPlatform() {
        for i in 1...5 { write(scenario: "A", runID: String(format: "202601%02d-000000Z-mach-700%d", i + 1, i)) }
        write(scenario: "A", runID: "20260101-000000Z-mach-0001", platform: "android")
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                  maxObservationsPerScenario: 5)
        XCTAssertTrue(records.contains { $0.platform == "android" },
                      "iOS の観測で枠が尽きて android が読めていない")
    }

    /// 記録を1件書く(machine を指定できる版)
    private func write(scenario: String, runID: String, machine: String, platform: String = "ios",
                       durationMs: Int = 100) {
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        var record = makeScenarioRecord(scenarioID: scenario, runID: runID)
        record.platform = platform
        record.host = machine
        record.durationMs = durationMs
        RunResultsStore.writeScenario(record, runDir: runDir, fileName: scenario)
    }

    /// machine ごとに別々に数える。リモート実行の回収記録が新しい側に並んでも、
    /// この機械の観測は cap 件ぶん別枠で確保され押し出されない
    func testObservationsAreCountedPerMachine() {
        for i in 1...5 {
            write(scenario: "A", runID: String(format: "202601%02d-000000Z-mach-750%d", i + 1, i),
                 machine: "リモート機")
        }
        write(scenario: "A", runID: "20260101-000000Z-mach-0001", machine: "この機械")
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                  maxObservationsPerScenario: 5)
        XCTAssertTrue(records.contains { $0.host == "この機械" },
                      "リモート機の観測で枠が尽きてこの機械が読めていない")
    }

    /// 遡りには上限がある(結果 JSON 全件を毎 run 読まない)。
    /// 満たされないシナリオが1本でもあると遡り続けるので、ここが唯一の歯止め
    func testScanStopsAtTheDirectoryLimit() {
        let limit = 3 * RunResultsStore.observationScanLimitFactor
        // 「B」は最古の1件しか無いので、上限が無ければ全件を読みに行く
        for i in 1...(limit + 5) {
            write(scenario: "A", runID: String(format: "2026%04d-000000Z-mach-600%d", 1000 + i, i))
        }
        write(scenario: "B", runID: "20260101-000000Z-mach-0001")
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir,
                                                  maxObservationsPerScenario: 3)
        XCTAssertFalse(records.contains { $0.scenarioID == "B" },
                       "打ち切りが効いていない(全 run を読んでいる)")
    }

    func testSchemaVersionTooNewIsSkipped() {
        let runID = "20260101-000000Z-mach-0002"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let futureMeta = makeMeta(
            runID: runID, startedAt: "2026-01-01T00:00:00Z", schemaVersion: RunRecordSchema.current + 1)
        RunResultsStore.writeMeta(futureMeta, runDir: runDir)

        XCTAssertTrue(RunResultsStore.scanRuns(resultsDir: resultsDir).isEmpty)

        var futureRecord = makeScenarioRecord(scenarioID: "Foo.baz", runID: runID)
        futureRecord.schemaVersion = RunRecordSchema.current + 1
        RunResultsStore.writeScenario(futureRecord, runDir: runDir, fileName: "Foo.baz")
        XCTAssertTrue(RunResultsStore.scanRecords(resultsDir: resultsDir).isEmpty)
    }

    func testCorruptedFileIsSkipped() throws {
        let runID = "20260101-000000Z-mach-0003"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!.write(to: runDir.appendingPathComponent("run.json"))

        XCTAssertTrue(RunResultsStore.scanRuns(resultsDir: resultsDir).isEmpty)
    }

    // MARK: - since/until プルーニング

    func testSinceUntilPruning() {
        let runA = "20260101-000000Z-mach-0001" // 2026-01
        let runB = "20260215-000000Z-mach-0002" // 2026-02
        let runC = "20260320-000000Z-mach-0003" // 2026-03
        for (runID, startedAt) in [
            (runA, "2026-01-01T00:00:00Z"),
            (runB, "2026-02-15T00:00:00Z"),
            (runC, "2026-03-20T00:00:00Z"),
        ] {
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
            RunResultsStore.writeMeta(makeMeta(runID: runID, startedAt: startedAt), runDir: runDir)
        }

        let formatter = ISO8601DateFormatter()
        let febStart = formatter.date(from: "2026-02-01T00:00:00Z")!
        let febEnd = formatter.date(from: "2026-02-28T23:59:59Z")!
        XCTAssertEqual(
            RunResultsStore.scanRuns(resultsDir: resultsDir, since: febStart, until: febEnd).map(\.runID),
            [runB])

        XCTAssertEqual(
            RunResultsStore.scanRuns(resultsDir: resultsDir, until: febStart).map(\.runID),
            [runA])

        let midFeb = formatter.date(from: "2026-02-16T00:00:00Z")!
        XCTAssertEqual(
            RunResultsStore.scanRuns(resultsDir: resultsDir, since: midFeb).map(\.runID),
            [runC])

        XCTAssertEqual(
            RunResultsStore.scanRuns(resultsDir: resultsDir).map(\.runID).sorted(),
            [runA, runB, runC].sorted())
    }

    // MARK: - RunRecorder

    func testRunRecorderSequentialNamingAndFinish() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        XCTAssertTrue(
            recorder.runID.range(of: #"^\d{8}-\d{6}Z-.+-[0-9a-f]{4}$"#, options: .regularExpression) != nil,
            "runID: \(recorder.runID)")

        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: true))
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: false))
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: false))
        recorder.recordSkipped(
            scenarioID: "Foo.skipped", title: nil, platform: "ios", worker: nil, reason: "対象外")

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let scenariosDir = runDir.appendingPathComponent("scenarios")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar~2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar~3.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.skipped.json").path))

        let skippedData = try? Data(contentsOf: scenariosDir.appendingPathComponent("Foo.skipped.json"))
        let skippedRecord = skippedData.flatMap { try? JSONDecoder().decode(ScenarioRunRecord.self, from: $0) }
        XCTAssertEqual(skippedRecord?.failedSteps?.first?.description, "対象外")

        recorder.finish(total: 4, passed: 1, failed: 3)
        let metaData = try? Data(contentsOf: runDir.appendingPathComponent("run.json"))
        let meta = metaData.flatMap { try? JSONDecoder().decode(RunMetaRecord.self, from: $0) }
        XCTAssertNotNil(meta?.finishedAt)
        XCTAssertEqual(meta?.total, 4)
        XCTAssertEqual(meta?.passed, 1)
        XCTAssertEqual(meta?.failed, 3)
        XCTAssertFalse(meta?.host.isEmpty ?? true)
    }

    /// issuer は begin() 時点で焼き込まれ、finish() でも同じ値が引き継がれる
    func testBeginAndFinishRecordIssuer() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let expected = LocalConfig.resolveIssuerId()

        let beginMeta = (try? Data(contentsOf: runDir.appendingPathComponent("run.json")))
            .flatMap { try? JSONDecoder().decode(RunMetaRecord.self, from: $0) }
        XCTAssertEqual(beginMeta?.issuer, expected)

        recorder.finish(total: 1, passed: 1, failed: 0)
        let finishMeta = (try? Data(contentsOf: runDir.appendingPathComponent("run.json")))
            .flatMap { try? JSONDecoder().decode(RunMetaRecord.self, from: $0) }
        XCTAssertEqual(finishMeta?.issuer, expected)
    }

    /// 旧 run.json(issuer キーが無い)も引き続き decode できる(schemaVersion は上げていない)
    func testRunMetaRecordDecodesOldJsonWithoutIssuerKey() throws {
        let raw = "{\"schemaVersion\":1,\"runID\":\"x\",\"project\":\"SampleApp\",\"machine\":\"m\","
            + "\"trigger\":\"cli\",\"startedAt\":\"2026-01-01T00:00:00Z\"}"
        let decoded = try XCTUnwrap(try? JSONDecoder().decode(RunMetaRecord.self, from: Data(raw.utf8)))
        XCTAssertNil(decoded.issuer)
    }

    /// measurementInvalid=false/未指定は run.json に一切書かれない(既存レコードと同じ形を保つ
    /// 契約。RunRecorder.finish の "false は nil で渡す" を確かめる)
    func testFinishOmitsMeasurementInvalidKeysWhenValid() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.finish(total: 1, passed: 1, failed: 0)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let raw = (try? Data(contentsOf: runDir.appendingPathComponent("run.json")))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(raw.contains("measurementInvalid"))

        let meta = (try? Data(contentsOf: runDir.appendingPathComponent("run.json")))
            .flatMap { try? JSONDecoder().decode(RunMetaRecord.self, from: $0) }
        XCTAssertNil(meta?.measurementInvalid)
        XCTAssertNil(meta?.measurementInvalidReasons)
    }

    /// measurementInvalid=true のときだけ理由とともに書かれ、往復で読み戻せる
    func testFinishRoundTripsMeasurementInvalidWhenSet() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.finish(total: 4, passed: 3, failed: 1,
                        measurementInvalid: true,
                        measurementInvalidReasons: ["2 lane(s) degraded or dropped during the run"])
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let meta = (try? Data(contentsOf: runDir.appendingPathComponent("run.json")))
            .flatMap { try? JSONDecoder().decode(RunMetaRecord.self, from: $0) }
        XCTAssertEqual(meta?.measurementInvalid, true)
        XCTAssertEqual(meta?.measurementInvalidReasons, ["2 lane(s) degraded or dropped during the run"])
    }

    func testDiscardLastRemovesFileAndRewindsCounter() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: false))

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let scenariosDir = runDir.appendingPathComponent("scenarios")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar.json").path))

        recorder.discardLast(scenarioID: "Foo.bar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar.json").path))

        // 連番カウンタが巻き戻り、再実行の記録が base 名(サフィックス無し)で書かれる
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Foo.bar~2.json").path))
    }

    /// **worker を名指しした取り消しは、その台の記録だけを消す**。`--broadcast` では同じ ID を
    /// N 台が同時に書くので、「この ID の最新」を消すと別の台の記録が消える
    func testDiscardLastWithWorkerRemovesOnlyThatWorkersRecord() throws {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.record(makeScenarioRecord(scenarioID: "Warm.up", runID: "", passed: false, worker: "ios:A"))
        recorder.record(makeScenarioRecord(scenarioID: "Warm.up", runID: "", passed: true, worker: "ios:B"))
        let scenariosDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
            .appendingPathComponent("scenarios")
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent(name).path)
        }
        XCTAssertTrue(exists("Warm.up.json") && exists("Warm.up~2.json"))

        // A(先に書いた方)の取り消し: B の ~2 は残る
        recorder.discardLast(scenarioID: "Warm.up", worker: "ios:A")
        XCTAssertFalse(exists("Warm.up.json"), "A の記録が消えていない")
        XCTAssertTrue(exists("Warm.up~2.json"), "B の記録が巻き添えで消えた")

        // 途中を消したので連番は巻き戻さない(巻き戻すと次の A の再実行が B の ~2 を上書きする)
        recorder.record(makeScenarioRecord(scenarioID: "Warm.up", runID: "", passed: true, worker: "ios:A"))
        XCTAssertTrue(exists("Warm.up~3.json"), "A の再実行は欠番の次に書く")
        let b = try JSONDecoder().decode(ScenarioRunRecord.self,
                                         from: Data(contentsOf: scenariosDir.appendingPathComponent("Warm.up~2.json")))
        XCTAssertEqual(b.worker, "ios:B")
        XCTAssertTrue(b.passed, "B の記録が A の再実行で上書きされた")
    }

    /// 記録していない worker を名指しした取り消しは何も消さない(別の台の記録を消すくらいなら黙る)
    func testDiscardLastWithUnknownWorkerIsNoop() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.record(makeScenarioRecord(scenarioID: "Warm.up", runID: "", passed: true, worker: "ios:A"))
        recorder.discardLast(scenarioID: "Warm.up", worker: "ios:Z")
        let scenariosDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
            .appendingPathComponent("scenarios")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenariosDir.appendingPathComponent("Warm.up.json").path))
    }

    func testDiscardLastOnUnrecordedScenarioIsNoop() {
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli", captureHostMetrics: false)
        recorder.discardLast(scenarioID: "Never.recorded")
        // クラッシュ・例外を起こさないことのみ確認する
    }

    func testRecordFillsRunIDMachineProfile() {
        let recorder = RunRecorder.begin(project: project, profile: "myProfile", trigger: "api", captureHostMetrics: false)
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: true))

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let data = try? Data(contentsOf: runDir.appendingPathComponent("scenarios/Foo.bar.json"))
        let record = data.flatMap { try? JSONDecoder().decode(ScenarioRunRecord.self, from: $0) }
        XCTAssertEqual(record?.runID, recorder.runID)
        XCTAssertEqual(record?.profile, "myProfile")
        XCTAssertFalse(record?.host.isEmpty ?? true)
    }
}
