// RunProgressLedger(フリート横断の run 進捗。docs/design.md §18)の検証。
// 守るもの: ①往復(write→readAll で同じ内容が返る) ②生存判定は pid だけ(死んだ pid は除外)
// ③壊れた JSON 1件が全体を巻き添えにしない ④既定ディレクトリはリテラルで固定する
// ⑤sweep は死んだ pid のぶんだけ消す(生きている run を消さない・自分の物でない名前に触らない)
// **版を揃える前提なので後方互換の decode は持たない**(ユーザー方針 2026-09-20)
// (FMUsageLedger と同じ規律。CLAUDE.md「既定値はリテラルで固定するテストを置く」)。

import XCTest
@testable import FTCore

final class RunProgressLedgerTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunProgressLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRecord(pid: Int32, done: Int = 1, failed: Int = 0,
                            phase: String = "running") -> RunProgressRecord {
        RunProgressRecord(
            pid: pid, runID: "run-\(pid)", runGroup: nil, issuer: "alice@air",
            project: "ec-mobile", profile: "ios-smoke", startedAt: "2026-09-20T10:03:12Z",
            total: 12, done: done, failed: failed, etaSeconds: nil,
            lanes: [RunProgressLane(key: "UDID-A", name: "iPhone 17-01", platform: "ios",
                                    scenario: "05_検索", scenarioStartedAt: "2026-09-20T10:04:00Z")],
            phase: phase)
    }

    func testDefaultDirectoryIsHomeDotFleetestRuns() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(RunProgressLedger.directory(home: home).path, "/Users/example/.fleetest/runs")
    }

    func testWriteThenReadAllRoundTrips() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord(pid: 41233)
        RunProgressLedger.write(record, directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true })
        XCTAssertEqual(read, [record])
    }

    func testWriteOverwritesThePreviousSnapshotForTheSamePID() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 41233, done: 1), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 41233, done: 7), directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true })
        XCTAssertEqual(read.map(\.done), [7], "同じ pid の2回目の書き込みが増分ではなく全体を上書きするはず")
    }

    func testRemoveDeletesTheFile() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 41233), directory: dir)
        RunProgressLedger.remove(pid: 41233, directory: dir)
        XCTAssertEqual(RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }), [])
    }

    /// **生存判定は pid だけ**(mtime を見ない)。死んだ pid の控えは読み手が無視する
    func testReadAllExcludesDeadPIDs() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 100), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 200), directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { $0 == 200 })
        XCTAssertEqual(read.map(\.pid), [200])
    }

    /// 壊れた JSON は**その1件だけ**飛ばす(全体を失わない)
    func testReadAllSkipsOnlyTheCorruptFileAndKeepsTheRest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 100), directory: dir)
        try "{ not valid json".write(to: dir.appendingPathComponent("200.json"),
                                    atomically: true, encoding: .utf8)
        RunProgressLedger.write(makeRecord(pid: 300), directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true })
        XCTAssertEqual(read.map(\.pid).sorted(), [100, 300])
    }

    /// sweep は**死んだ pid のぶんだけ**消す。生きている run の控えを消すと、その run が
    /// モニターから消えたまま最後まで戻らない(次の write まで空白になる)
    func testSweepRemovesOnlyDeadPIDs() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 100), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 200), directory: dir)
        RunProgressLedger.sweep(directory: dir, isAlive: { $0 == 200 })
        let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names?.sorted(), ["200.json"])
    }

    /// **pid としてパースできない名前には触らない**(この台帳が作った物ではない)
    func testSweepLeavesFilesThatAreNotPIDNames() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        RunProgressLedger.sweep(directory: dir, isAlive: { _ in false })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.json"])
    }

    func testSweepOnAMissingDirectoryDoesNotCrash() {
        let dir = tempDir().appendingPathComponent("does-not-exist", isDirectory: true)
        RunProgressLedger.sweep(directory: dir, isAlive: { _ in false })
    }

    func testReadAllOnAMissingDirectoryReturnsEmpty() {
        let dir = tempDir().appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }), [])
    }

    /// "preparing" が往復する(段階「準備中」)
    func testPreparingPhaseRoundTrips() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord(pid: 41233, phase: "preparing")
        RunProgressLedger.write(record, directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true })
        XCTAssertEqual(read, [record])
        XCTAssertEqual(read.first?.phase, "preparing")
    }

}
