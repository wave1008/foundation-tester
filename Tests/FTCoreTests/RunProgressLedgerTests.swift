// RunProgressLedger(フリート横断の run 進捗。docs/design.md §18)の検証。
// 守るもの: ①往復(write→readAll で同じ内容が返る) ②生存判定は pid + startedAt
// (死んだ pid・記録より後に始まった pid = 再利用は除外) ③壊れた JSON 1件が全体を巻き添えにしない
// ④既定ディレクトリはリテラルで固定する ⑤sweep は死んだ pid のぶんだけ消す
// (生きている run を消さない・自分の物でない名前に触らない)
// **版を揃える前提なので後方互換の decode は持たない**(ユーザー方針 2026-09-20)
// (FMUsageLedger と同じ規律。CLAUDE.md「既定値はリテラルで固定するテストを置く」)。

import XCTest
@testable import FTCore

final class RunProgressLedgerTests: XCTestCase {
    /// isAlive を差し替えるテストは開始時刻も差し替える(既定の実 startTime は手元に実在する同じ pid を読み、
    /// ホストのプロセス表しだいで「記録より後に起動 = 別物」と判定されて結果が揺れる)
    private static let unknownStart: (Int32) -> Date? = { _ in nil }


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
            total: 12, done: done, failed: failed, requeued: 0, laneDropouts: 0, etaSeconds: nil,
            lanes: [RunProgressLane(key: "UDID-A", name: "iPhone 17-01", platform: "ios",
                                    scenario: "05_検索", scenarioStartedAt: "2026-09-20T10:04:00Z",
                                    expectedSeconds: nil)],
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
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read, [record])
    }

    func testWriteOverwritesThePreviousSnapshotForTheSamePID() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 41233, done: 1), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 41233, done: 7), directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read.map(\.done), [7], "同じ pid の2回目の書き込みが増分ではなく全体を上書きするはず")
    }

    func testRemoveDeletesTheFile() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 41233), directory: dir)
        RunProgressLedger.remove(pid: 41233, directory: dir)
        XCTAssertEqual(RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart), [])
    }

    /// **生存判定は pid だけ**(mtime を見ない)。死んだ pid の控えは読み手が無視する
    func testReadAllExcludesDeadPIDs() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 100), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 200), directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { $0 == 200 }, startTime: Self.unknownStart)
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
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read.map(\.pid).sorted(), [100, 300])
    }

    /// sweep は**死んだ pid のぶんだけ**消す。生きている run の控えを消すと、その run が
    /// モニターから消えたまま最後まで戻らない(次の write まで空白になる)
    func testSweepRemovesOnlyDeadPIDs() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 100), directory: dir)
        RunProgressLedger.write(makeRecord(pid: 200), directory: dir)
        RunProgressLedger.sweep(directory: dir, isAlive: { $0 == 200 }, startTime: Self.unknownStart)
        let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names?.sorted(), ["200.json"])
    }

    /// **pid としてパースできない名前には触らない**(この台帳が作った物ではない)
    func testSweepLeavesFilesThatAreNotPIDNames() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        RunProgressLedger.sweep(directory: dir, isAlive: { _ in false }, startTime: Self.unknownStart)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.json"])
    }

    func testSweepOnAMissingDirectoryDoesNotCrash() {
        let dir = tempDir().appendingPathComponent("does-not-exist", isDirectory: true)
        RunProgressLedger.sweep(directory: dir, isAlive: { _ in false }, startTime: Self.unknownStart)
    }

    func testReadAllOnAMissingDirectoryReturnsEmpty() {
        let dir = tempDir().appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart), [])
    }

    // MARK: - pid 再利用(startedAt との突き合わせ)

    /// **pid の再利用**: 死んだ run の pid が、記録(startedAt)より後に生まれた別プロセスへ
    /// 再利用されると、pid だけの生死判定はそれを「生きている」と読み続けてしまう。
    /// startedAt との突き合わせで「記録より後に始まった別物」を死んだ扱いにできることを固定する
    func testReadAllTreatsAReusedPidAsDead() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 500), directory: dir)  // startedAt = 2026-09-20T10:03:12Z
        let read = RunProgressLedger.readAll(
            directory: dir, isAlive: { _ in true },
            // pid は生きているが、実際の開始は記録よりずっと後 = 別プロセスの証拠
            startTime: { _ in ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z") })
        XCTAssertEqual(read, [], "記録より後に始まった pid を同じ run のまま読んでいる")
    }

    /// **陰性対照**: 開始時刻が記録以前(= 本当に同じプロセス)なら従来どおり生きている扱いのまま
    func testReadAllKeepsAGenuinelyLiveProcessWhoseStartPredatesTheRecord() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord(pid: 500)
        RunProgressLedger.write(record, directory: dir)
        let read = RunProgressLedger.readAll(
            directory: dir, isAlive: { _ in true },
            startTime: { _ in ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z") })
        XCTAssertEqual(read, [record])
    }

    /// sweep も同じ再利用判定を通す(`readAll` と別の判定を持たない)
    func testSweepRemovesAReusedPidsStaleRecord() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 500), directory: dir)
        RunProgressLedger.sweep(
            directory: dir, isAlive: { _ in true },
            startTime: { _ in ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z") })
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "記録より後に始まった pid の控えが残っている(再利用を見逃している)")
    }

    /// sweep の陰性対照: 本当に生きている(開始が記録以前の)pid の控えは消さない
    func testSweepKeepsAGenuinelyLiveProcessWhoseStartPredatesTheRecord() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunProgressLedger.write(makeRecord(pid: 500), directory: dir)
        RunProgressLedger.sweep(
            directory: dir, isAlive: { _ in true },
            startTime: { _ in ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z") })
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: dir.path), ["500.json"])
    }

    /// "preparing" が往復する(段階「準備中」)
    func testPreparingPhaseRoundTrips() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord(pid: 41233, phase: "preparing")
        RunProgressLedger.write(record, directory: dir)
        let read = RunProgressLedger.readAll(directory: dir, isAlive: { _ in true }, startTime: Self.unknownStart)
        XCTAssertEqual(read, [record])
        XCTAssertEqual(read.first?.phase, "preparing")
    }

}
