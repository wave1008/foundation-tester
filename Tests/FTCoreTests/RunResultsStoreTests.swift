import XCTest
@testable import FTCore

final class RunResultsStoreTests: XCTestCase {
    var repoRoot: URL!
    var project: TestProject!
    var resultsDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunResultsStoreTests-\(UUID().uuidString)")
        project = TestProject(name: "SampleApp", rootURL: repoRoot.appendingPathComponent("Projects/SampleApp"))
        resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeMeta(runID: String, startedAt: String, schemaVersion: Int = RunRecordSchema.current) -> RunMetaRecord {
        RunMetaRecord(
            schemaVersion: schemaVersion, runID: runID, project: "SampleApp", profile: nil,
            machine: "testmachine", trigger: "cli", startedAt: startedAt)
    }

    private func makeScenarioRecord(scenarioID: String, runID: String, passed: Bool = true) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, platform: "ios", machine: "testmachine",
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
        let recorder = RunRecorder.begin(project: project, profile: "default", trigger: "cli")
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
        XCTAssertFalse(meta?.machine.isEmpty ?? true)
    }

    func testRecordFillsRunIDMachineProfile() {
        let recorder = RunRecorder.begin(project: project, profile: "myProfile", trigger: "api")
        recorder.record(makeScenarioRecord(scenarioID: "Foo.bar", runID: "", passed: true))

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
        let data = try? Data(contentsOf: runDir.appendingPathComponent("scenarios/Foo.bar.json"))
        let record = data.flatMap { try? JSONDecoder().decode(ScenarioRunRecord.self, from: $0) }
        XCTAssertEqual(record?.runID, recorder.runID)
        XCTAssertEqual(record?.profile, "myProfile")
        XCTAssertFalse(record?.machine.isEmpty ?? true)
    }
}
