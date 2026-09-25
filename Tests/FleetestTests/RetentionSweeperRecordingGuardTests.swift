// finishedAt の無い run(録画)の guarded 判定は pid だけでなく startedAt も見て、
// pid の再利用(死んだ run の pid が別の、今生きているプロセスへ再利用される)を弾くことを確かめる。
// `RetentionSweeper.runIsGuarded` は private なので、production の入口
// `sessions(for: .recordings, roots:, activeRunID:)` をそのまま通して確かめる。

import FTCore
import XCTest
@testable import fleetest

final class RetentionSweeperRecordingGuardTests: XCTestCase {

    private var packageRoot: URL!
    private let projectName = "guard-app"

    override func setUpWithError() throws {
        try super.setUpWithError()
        packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageRoot.appendingPathComponent("TestProjects/\(projectName)"),
            withIntermediateDirectories: true)
        let root = packageRoot!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func makeRun(runID: String, host: String, pid: Int?, startedAt: String,
                         finishedAt: String?) throws -> URL {
        let project = TestProject(
            name: projectName, rootURL: packageRoot.appendingPathComponent("TestProjects/\(projectName)"))
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let meta = RunMetaRecord(runID: runID, project: projectName, profile: nil, host: host,
                                 trigger: "cli", startedAt: startedAt, finishedAt: finishedAt, pid: pid)
        RunResultsStore.writeMeta(meta, runDir: runDir)
        // `measure(directory:)` は中身が要る(空でも起点の mtime は持てるが、セッションとして
        // 拾われるにはディレクトリ自体が存在すれば足りる。1ファイル置いて実運用に近づける)
        let recordings = runDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: recordings.appendingPathComponent("a.mp4"))
        return runDir
    }

    private func guardedValue(runID: String) throws -> Bool {
        let roots = RetentionSweeper.Roots(package: packageRoot, tool: packageRoot)
        let sessions = RetentionSweeper.sessions(for: .recordings, roots: roots, activeRunID: nil)
        let session = try XCTUnwrap(sessions.first { $0.id == runID },
                                    "recordings セッションが見つからない: \(sessions.map(\.id))")
        return session.guarded
    }

    func testAFinishedRunIsNotGuarded() throws {
        let runID = "20260920-100000Z-finished"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(), pid: 1,
                    startedAt: "2026-09-20T10:00:00Z", finishedAt: "2026-09-20T10:05:00Z")
        XCTAssertFalse(try guardedValue(runID: runID))
    }

    /// 別の機械の run(host 不一致)は判断できないので従来どおり守る
    func testAnUnfinishedRunFromAnotherHostIsGuarded() throws {
        let runID = "20260920-100000Z-otherhost"
        try makeRun(runID: runID, host: "someone-elses-mac", pid: 1,
                    startedAt: "2026-09-20T10:00:00Z", finishedAt: nil)
        XCTAssertTrue(try guardedValue(runID: runID))
    }

    /// pid の無い記録(旧版)は判断できないので従来どおり守る
    func testAnUnfinishedRunWithNoPidIsGuarded() throws {
        let runID = "20260920-100000Z-nopid"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(), pid: nil,
                    startedAt: "2026-09-20T10:00:00Z", finishedAt: nil)
        XCTAssertTrue(try guardedValue(runID: runID))
    }

    /// **本物の欠陥の再現**: pid が本当に死んでいる(存在しない pid)なら保護を外してよい ——
    /// 直す前は finishedAt が無いというだけで無条件に guarded=true のままだった(このセッションの
    /// 録画は SIGKILL・クラッシュ・電源断で永久に消せなかった)
    func testAnUnfinishedRunWithADeadPidIsNoLongerGuarded() throws {
        let deadPid = Int32.max - 7  // 通常割り当てられない領域(衝突しうるので前提を確認する)
        try XCTSkipUnless(!ProcessLiveness.isAlive(deadPid),
                          "pid \(deadPid) unexpectedly exists on this host")
        let runID = "20260920-100000Z-deadpid"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(), pid: Int(deadPid),
                    startedAt: "2026-09-20T10:00:00Z", finishedAt: nil)
        XCTAssertFalse(try guardedValue(runID: runID))
    }

    /// **pid の再利用**: 記録の pid は今、本当に生きている別のプロセス(このテスト自身)へ
    /// 再割り当てされている。実際の開始は startedAt よりずっと後なので「記録した pid とは別物」
    /// として保護を外す。**pid の生死だけを見ていた旧実装は、この pid が生きている限り
    /// この録画を永久に守り続けた**(この欠陥そのものの再現)
    func testAnUnfinishedRunWhosePidWasReusedByAnotherLiveProcessIsNoLongerGuarded() throws {
        let runID = "20260920-100000Z-reused"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(),
                    pid: Int(ProcessInfo.processInfo.processIdentifier),
                    startedAt: "2000-01-01T00:00:00Z", finishedAt: nil)
        XCTAssertFalse(try guardedValue(runID: runID))
    }

    /// **陰性対照**: 本当に生きている(実際の開始が記録以前の)自分自身の pid は従来どおり守る ——
    /// 「常に保護を外す実装」と区別する
    func testAGenuinelyRunningRunIsStillGuarded() throws {
        let runID = "20260920-100000Z-alive"
        try makeRun(runID: runID, host: RunRecorder.currentMachine(),
                    pid: Int(ProcessInfo.processInfo.processIdentifier),
                    startedAt: ISO8601DateFormatter().string(from: Date()), finishedAt: nil)
        XCTAssertTrue(try guardedValue(runID: runID))
    }
}
