// サブ実行のクラッシュで結果が1件も残らないシナリオを検出する経路
// (DeviceMachineRunner.reportMissingResults の下請け)の単体テスト。
// 負荷テストの実測(bug-audit): `fleetest run --runner local` を SIGKILL すると、担当 11 本のうち
// 9 本が run.json に finishedAt 無し・scenarios は 2 件だけになり、`--failed` が拾えなくなっていた。

import XCTest
import FTCore
@testable import fleetest

private func makeMeta(runID: String, startedAt: String, runGroup: String?) -> RunMetaRecord {
    RunMetaRecord(runID: runID, project: "SampleApp", profile: "p", host: "testmachine",
                 trigger: "cli", startedAt: startedAt, runGroup: runGroup)
}

private func makeScenarioRecord(scenarioID: String, runID: String, interrupted: Bool = false) -> ScenarioRunRecord {
    var record = ScenarioRunRecord(runID: runID, scenarioID: scenarioID, platform: "ios", host: "testmachine",
                                   passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                                   steps: StepCountsRecord(total: 1, passed: 1))
    if interrupted { record.interrupted = true }
    return record
}

final class DeviceMachineRunnerMissingResultsTests: XCTestCase {

    // MARK: - unrecordedScenarioIDs(純粋関数)

    func testUnrecordedScenarioIDsReturnsEmptyWhenAllRecorded() {
        let missing = DeviceMachineRunner.unrecordedScenarioIDs(
            assigned: ["A.s1", "A.s2"], recorded: ["A.s1", "A.s2"])
        XCTAssertEqual(missing, [])
    }

    func testUnrecordedScenarioIDsFindsTheGap() {
        let missing = DeviceMachineRunner.unrecordedScenarioIDs(
            assigned: ["A.s1", "A.s2", "A.s3"], recorded: ["A.s1"])
        XCTAssertEqual(missing, ["A.s2", "A.s3"])
    }

    /// 順序は assigned のまま(recorded は Set なので並びを持たない)
    func testUnrecordedScenarioIDsPreservesAssignedOrder() {
        let missing = DeviceMachineRunner.unrecordedScenarioIDs(
            assigned: ["Z.s1", "A.s1", "M.s1"], recorded: [])
        XCTAssertEqual(missing, ["Z.s1", "A.s1", "M.s1"])
    }

    // MARK: - missingResultsLine(純粋関数)

    func testMissingResultsLineListsAllIDsUnderTheCap() {
        let line = DeviceMachineRunner.missingResultsLine(
            machineLabel: "M1Ultra", exitCode: 255, ids: ["A.s1", "A.s2"])
        XCTAssertTrue(line.contains("M1Ultra"))
        XCTAssertTrue(line.contains("2 scenario(s)"))
        XCTAssertTrue(line.contains("sub-run exited 255"))
        XCTAssertTrue(line.contains("A.s1, A.s2"))
        XCTAssertFalse(line.contains("…"))
    }

    /// 5件を超えたら先頭5件 + "…"(全件の本数は "N scenario(s)" に必ず出る)
    func testMissingResultsLineTruncatesLongLists() {
        let ids = (1...9).map { "A.s\($0)" }
        let line = DeviceMachineRunner.missingResultsLine(
            machineLabel: "M1Ultra", exitCode: 255, ids: ids)
        XCTAssertTrue(line.contains("9 scenario(s)"))
        XCTAssertTrue(line.contains("A.s1, A.s2, A.s3, A.s4, A.s5"))
        XCTAssertFalse(line.contains("A.s6"))
        XCTAssertTrue(line.hasSuffix("…"))
    }

    // MARK: - interruptedResultsLine(純粋関数)

    func testInterruptedResultsLineListsAllIDsUnderTheCap() {
        let line = DeviceMachineRunner.interruptedResultsLine(
            machineLabel: "M1Max", exitCode: 137, ids: ["A.s1"])
        XCTAssertTrue(line.contains("M1Max"))
        XCTAssertTrue(line.contains("1 scenario(s) were interrupted"))
        XCTAssertTrue(line.contains("sub-run exited 137"))
        XCTAssertTrue(line.contains("A.s1"))
        XCTAssertFalse(line.contains("…"))
    }

    func testInterruptedResultsLineTruncatesLongLists() {
        let ids = (1...9).map { "A.s\($0)" }
        let line = DeviceMachineRunner.interruptedResultsLine(
            machineLabel: "M1Max", exitCode: 137, ids: ids)
        XCTAssertTrue(line.contains("9 scenario(s) were interrupted"))
        XCTAssertTrue(line.contains("A.s1, A.s2, A.s3, A.s4, A.s5"))
        XCTAssertFalse(line.contains("A.s6"))
        XCTAssertTrue(line.hasSuffix("…"))
    }

    // MARK: - recordedScenarioIDs(results/ ツリーからの集計)

    var repoRoot: URL!
    var project: TestProject!
    var resultsDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeviceMachineRunnerMissingResultsTests-\(UUID().uuidString)")
        project = TestProject(name: "SampleApp",
                              rootURL: repoRoot.appendingPathComponent("TestProjects/SampleApp"))
        resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    /// 同じ runGroup を持つ2つの run ディレクトリ(手元の子 + 回収したリモートの子を模す)の
    /// scenario record を1つの集合へ畳む
    func testRecordedScenarioIDsUnionsAllRunDirsInTheSameGroup() {
        let group = "20260101-000000Z-abcd1234"
        let localRunID = "20260101-000100Z-mach-0001"
        let remoteRunID = "20260101-000100Z-mach-0002"
        let localRunDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: localRunID)
        let remoteRunDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: remoteRunID)

        RunResultsStore.writeMeta(
            makeMeta(runID: localRunID, startedAt: "2026-01-01T00:01:00Z", runGroup: group),
            runDir: localRunDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "A.s1", runID: localRunID),
                                      runDir: localRunDir, fileName: "A.s1")

        RunResultsStore.writeMeta(
            makeMeta(runID: remoteRunID, startedAt: "2026-01-01T00:01:05Z", runGroup: group),
            runDir: remoteRunDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "B.s1", runID: remoteRunID),
                                      runDir: remoteRunDir, fileName: "B.s1")
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "B.s2", runID: remoteRunID),
                                      runDir: remoteRunDir, fileName: "B.s2")

        let recorded = DeviceMachineRunner.recordedScenarioIDs(
            project: project, runGroup: group,
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!)
        XCTAssertEqual(recorded, ["A.s1", "B.s1", "B.s2"])
    }

    /// 別の runGroup(=別の実行)の記録は混ぜない
    func testRecordedScenarioIDsExcludesOtherRunGroups() {
        let group = "20260101-000000Z-abcd1234"
        let otherGroup = "20260101-000000Z-ffff0000"
        let runID = "20260101-000100Z-mach-0001"
        let otherRunID = "20260101-000100Z-mach-0002"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let otherRunDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: otherRunID)

        RunResultsStore.writeMeta(
            makeMeta(runID: runID, startedAt: "2026-01-01T00:01:00Z", runGroup: group),
            runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "A.s1", runID: runID),
                                      runDir: runDir, fileName: "A.s1")

        RunResultsStore.writeMeta(
            makeMeta(runID: otherRunID, startedAt: "2026-01-01T00:01:00Z", runGroup: otherGroup),
            runDir: otherRunDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "C.s1", runID: otherRunID),
                                      runDir: otherRunDir, fileName: "C.s1")

        let recorded = DeviceMachineRunner.recordedScenarioIDs(
            project: project, runGroup: group,
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!)
        XCTAssertEqual(recorded, ["A.s1"])
    }

    /// クラッシュを模す: 割り当てた3本のうち1本しか scenario record が無い run ディレクトリから、
    /// 欠落2本を正しく突き止める(reportMissingResults が読む2段(recordedScenarioIDs →
    /// unrecordedScenarioIDs)の結合)
    func testRecordedScenarioIDsReflectsAPartiallyCrashedSubRun() {
        let group = "20260101-000000Z-abcd1234"
        let runID = "20260101-000100Z-mach-0001"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)

        RunResultsStore.writeMeta(
            makeMeta(runID: runID, startedAt: "2026-01-01T00:01:00Z", runGroup: group),
            runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "A.s1", runID: runID),
                                      runDir: runDir, fileName: "A.s1")
        // A.s2 / A.s3 は書かれる前にサブ実行が SIGKILL された想定(意図的に書かない)

        let recorded = DeviceMachineRunner.recordedScenarioIDs(
            project: project, runGroup: group,
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!)
        let missing = DeviceMachineRunner.unrecordedScenarioIDs(
            assigned: ["A.s1", "A.s2", "A.s3"], recorded: recorded)
        XCTAssertEqual(missing, ["A.s2", "A.s3"])
    }

    // M7b: 中断されたまま記録が残った分は `all`(=「記録あり」)には数えられるが missing には
    // 出ない。別枠(`interrupted`)で拾えることを確かめる ——
    // 実測: リモート機は中断された1本を scenarios/*.json に interrupted: true で記録したが、
    // 手元は「記録あり」としか見ておらず、欠落としても中断としても一度も知らされなかった
    func testScanRecordedScenariosSeparatesInterruptedFromNormalRecords() {
        let group = "20260101-000000Z-abcd1234"
        let runID = "20260101-000100Z-mach-0001"
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)

        RunResultsStore.writeMeta(
            makeMeta(runID: runID, startedAt: "2026-01-01T00:01:00Z", runGroup: group),
            runDir: runDir)
        RunResultsStore.writeScenario(makeScenarioRecord(scenarioID: "A.s1", runID: runID),
                                      runDir: runDir, fileName: "A.s1")
        RunResultsStore.writeScenario(
            makeScenarioRecord(scenarioID: "A.s2", runID: runID, interrupted: true),
            runDir: runDir, fileName: "A.s2")

        let recorded = DeviceMachineRunner.scanRecordedScenarios(
            project: project, runGroup: group,
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!)
        XCTAssertEqual(recorded.all, ["A.s1", "A.s2"], "中断された分も「記録あり」に数える")
        XCTAssertEqual(recorded.interrupted, ["A.s2"])
        // missing(assigned - all)には出ない — 記録はある
        XCTAssertEqual(DeviceMachineRunner.unrecordedScenarioIDs(
            assigned: ["A.s1", "A.s2"], recorded: recorded.all), [])
    }
}
