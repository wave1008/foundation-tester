// シナリオごとの実行ログ(events/)の保持容量掃除。単位は run 1件(recordingSessions と同じ規律)で、
// guarded の判定も同じ `runIsGuarded` を共有するので、pid 再利用等の細かい境界は
// RetentionSweeperRecordingGuardTests が既に固定している。ここは events 系統固有の配線
// (`.eventLogs` カテゴリが `events/` ディレクトリ単位で古い run から消え、進行中の run は消さない)だけ確かめる。

import FTCore
import XCTest
@testable import fleetest

final class RetentionSweeperEventLogsTests: XCTestCase {

    private var packageRoot: URL!
    private let projectName = "events-app"

    override func setUpWithError() throws {
        try super.setUpWithError()
        packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageRoot.appendingPathComponent("TestProjects/\(projectName)"),
            withIntermediateDirectories: true)
        let root = packageRoot!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private var project: TestProject {
        TestProject(name: projectName, rootURL: packageRoot.appendingPathComponent("TestProjects/\(projectName)"))
    }

    private func eventsDir(runID: String) -> URL {
        RunResultsStore.runDir(resultsDir: RunResultsStore.resultsDir(projectRoot: project.rootURL), runID: runID)
            .appendingPathComponent("events")
    }

    private func runJSON(runID: String) -> URL {
        RunResultsStore.runDir(resultsDir: RunResultsStore.resultsDir(projectRoot: project.rootURL), runID: runID)
            .appendingPathComponent("run.json")
    }

    /// **modified を明示指定**(同着だと plan の並びがテストの意図と違う側を消しうる。
    /// RetentionSweeperXcresultTests / DumpRetentionTests と同じ方式)
    @discardableResult
    private func makeRun(runID: String, host: String, pid: Int?, startedAt: String,
                         finishedAt: String?, bytes: Int = 1, modified: Date? = nil) throws -> URL {
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let meta = RunMetaRecord(runID: runID, project: projectName, profile: nil, host: host,
                                 trigger: "cli", startedAt: startedAt, finishedAt: finishedAt, pid: pid)
        RunResultsStore.writeMeta(meta, runDir: runDir)
        let events = runDir.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let file = events.appendingPathComponent("S0010.ndjson")
        try Data(repeating: 0x41, count: bytes).write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: events.path)
        }
        return runDir
    }

    private func roots() -> RetentionSweeper.Roots {
        RetentionSweeper.Roots(package: packageRoot, tool: packageRoot)
    }

    /// 単位は run 1件 = `events/` ディレクトリ丸ごと(確定分・`.inflight-*` を区別しない)
    func testSessionUnitIsTheEventsDirectoryPerRun() throws {
        let runID = "20260928-100000Z-finished"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(), pid: 1,
                    startedAt: "2026-09-28T10:00:00Z", finishedAt: "2026-09-28T10:05:00Z")
        let sessions = RetentionSweeper.sessions(for: .eventLogs, roots: roots(), activeRunID: nil)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, runID)
        XCTAssertFalse(sessions[0].guarded)
    }

    /// 進行中の run(`activeRunID`)の `events/` は上限を超えても消えない。消えるのは古い run から
    func testCleanRemovesTheOldestRunFirstAndNeverTheActiveRun() throws {
        let oldRunID = "20260928-090000Z-old"
        try makeRun(runID: oldRunID, host: RunRecorder.currentMachine(), pid: 1,
                    startedAt: "2026-09-28T09:00:00Z", finishedAt: "2026-09-28T09:05:00Z",
                    bytes: 5 * 1_048_576, modified: Date().addingTimeInterval(-3600))
        let activeRunID = "20260928-100000Z-active"
        try makeRun(runID: activeRunID, host: RunRecorder.currentMachine(), pid: 1,
                    startedAt: "2026-09-28T10:00:00Z", finishedAt: nil, bytes: 5 * 1_048_576)

        let report = RetentionSweeper.clean(
            roots: roots(), categories: [.eventLogs],
            policy: RetentionPolicy(eventLogsMaxBytes: 1 * 1_048_576),  // 1 MiB cap forces a sweep
            dryRun: false, activeRunID: activeRunID, log: { _ in }, notice: { _ in })

        XCTAssertEqual(report.categories.first?.deletedSessions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsDir(runID: oldRunID).path),
                       "古い run の events/ は消える")
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsDir(runID: activeRunID).path),
                      "進行中の run の events/ は消えない")
        // 結果 JSON(run.json)は保持の掃除対象外 —— run の履歴・LPT の実績が失われないこと
        XCTAssertTrue(FileManager.default.fileExists(atPath: runJSON(runID: oldRunID).path),
                      "結果 JSON は消さない")
    }

    /// finishedAt が無く、かつこの機械の生きているプロセスと確定できない run(pid 無し)は
    /// activeRunID の指定が無くても安全側で守られる(recordingSessions と同じ `runIsGuarded`)
    func testAnUnfinishedRunWithNoPidIsGuardedEvenWithoutAnActiveRunID() throws {
        let runID = "20260928-110000Z-nopid"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(), pid: nil,
                    startedAt: "2026-09-28T11:00:00Z", finishedAt: nil)
        let sessions = RetentionSweeper.sessions(for: .eventLogs, roots: roots(), activeRunID: nil)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].guarded)
    }
}
