// FMUsageLedger(FM 呼び出しの機械グローバルな控え)の検証。
// 生存判定に実際の kill(2) を使うため、SharedResource.hostCaches で直列化する
// (CLAUDE.md: 隔離できないホストの実体に触るテストの規律。ここでは env 越しに書き込み先を
// テストごとの一時ディレクトリへ差し替えているが、FT_FM_USAGE_DIR 自体はプロセス全体の状態)。

import FTTestSupport
import XCTest
@testable import FTCore

final class FMUsageLedgerTests: XCTestCase {
    private var dir: URL!
    private var savedEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMUsageLedgerTests-\(UUID().uuidString)")
        savedEnv = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"]
        setenv("FT_FM_USAGE_DIR", dir.path, 1)
    }

    override func tearDownWithError() throws {
        if let savedEnv { setenv("FT_FM_USAGE_DIR", savedEnv, 1) } else { unsetenv("FT_FM_USAGE_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 確実に存在しない pid(DeviceFrozenStoreTests と同じ選び方。kill(pid, 0) が ESRCH を返す領域)
    private let deadPID: Int32 = 2_000_000

    func testRecordThenDrainYieldsIncrementOnly() throws {
        try SharedResource.hostCaches.locked {
            var previous: [Int32: FMUsageLedger.Counters]? = nil

            FMUsageLedger.record(ok: true, ms: 100)
            let first = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(first?.calls, 0, "初見の pid は増分0")

            FMUsageLedger.record(ok: true, ms: 50)
            FMUsageLedger.record(ok: false, ms: 25)
            let second = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(second?.calls, 2)
            XCTAssertEqual(second?.failures, 1)
            XCTAssertEqual(second?.totalMs, 75)
        }
    }

    /// 基準取り(previous == nil)の回は、監視開始前から在る累計をスパイクとして出さない
    func testBaselineDrainNeverSpikes() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let selfPID = ProcessInfo.processInfo.processIdentifier
            try writeRawEntry(pid: selfPID, calls: 500, failures: 10, totalMs: 60000)

            var previous: [Int32: FMUsageLedger.Counters]? = nil
            let delta = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 0)
            XCTAssertEqual(previous?[selfPID]?.calls, 500, "次回からの基準にするため控え自体は保持する")
        }
    }

    /// 基準取りの**後**に現れた pid は全量が増分。ここを 0 にすると、シナリオごとに立ち上がる
    /// ランナープロセスの呼び出しが毎回落ちる(実測で 61 回中 12 回を落とした退行)
    func testPidAppearingAfterBaselineIsCountedInFull() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var previous: [Int32: FMUsageLedger.Counters]? = nil
            XCTAssertEqual(FMUsageLedger.drain(previous: &previous)?.calls, 0, "基準取り")

            let latePID = ProcessInfo.processInfo.processIdentifier
            try writeRawEntry(pid: latePID, calls: 7, failures: 2, totalMs: 900)
            let delta = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 7)
            XCTAssertEqual(delta?.failures, 2)
            XCTAssertEqual(delta?.totalMs, 900)
        }
    }

    /// **死んだ pid のぶんも計上する**。ランナーはシナリオを終えるとすぐ死ぬので、
    /// 生きている pid だけを数えると最後の呼び出しがまるごと消える
    func testDeadPidCallsAreStillCounted() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var previous: [Int32: FMUsageLedger.Counters]? = nil
            XCTAssertEqual(FMUsageLedger.drain(previous: &previous)?.calls, 0, "基準取り")

            try writeRawEntry(pid: deadPID, calls: 5, failures: 1, totalMs: 500)
            let delta = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 5, "死んでいても計上する")
            XCTAssertEqual(delta?.failures, 1)
            XCTAssertEqual(FMUsageLedger.drain(previous: &previous)?.calls, 0, "次の tick で二重に数えない")
        }
    }

    /// **読みは非破壊**。読み手は複数居る(拡張の api host-metrics と run の HostMetricsRecorder)ので、
    /// 読んだ側が消すと先に消したほうだけが数え、もう片方はそのプロセスのぶんを丸ごと落とす
    func testDrainDoesNotDeleteEntries() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeRawEntry(pid: deadPID, calls: 5, failures: 0, totalMs: 500)
            let url = dir.appendingPathComponent("\(deadPID).json")

            // 2人の読み手を模す(それぞれ独立した previous を持つ)
            var readerA: [Int32: FMUsageLedger.Counters]? = [:]
            var readerB: [Int32: FMUsageLedger.Counters]? = [:]
            XCTAssertEqual(FMUsageLedger.drain(previous: &readerA)?.calls, 5)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "読みで消さない")
            XCTAssertEqual(FMUsageLedger.drain(previous: &readerB)?.calls, 5,
                          "もう片方の読み手も同じ増分を見られる")
        }
    }

    /// ディレクトリが無い = この機械でまだ一度も FM を呼んでいない。**不明ではなく 0 件**
    /// (不明にすると FM を使わない機械の行が永久に「–」になり壊れて見える)
    func testMissingDirectoryIsZeroNotUnknown() throws {
        try SharedResource.hostCaches.locked {
            var previous: [Int32: FMUsageLedger.Counters]? = nil
            let delta = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 0)
            XCTAssertEqual(delta?.failures, 0)
            XCTAssertEqual(delta?.totalMs, 0)
        }
    }

    /// ディレクトリはあるが一覧できない = **不明**(nil)。0 件と混ぜない
    func testUnreadableDirectoryIsUnknown() throws {
        try XCTSkipIf(getuid() == 0, "root は権限で弾かれないため判定できない")
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

            var previous: [Int32: FMUsageLedger.Counters]? = nil
            XCTAssertNil(FMUsageLedger.drain(previous: &previous),
                        "読めないときは nil(不明)であって 0 ではない")
        }
    }

    /// 壊れた JSON のファイルが混ざっても、生存中の他ファイルの集計は壊れない。
    /// 破損ファイルの pid には「このテストプロセスの親プロセス」を使う ——
    /// 死んだ pid だと isAlive の時点で reap され、検証したい decode 失敗の経路を素通りしてしまう
    func testCorruptFileDoesNotBreakOtherEntries() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let parentPID = getppid()
            let corruptURL = dir.appendingPathComponent("\(parentPID).json")
            try Data("{not valid json".utf8).write(to: corruptURL)

            var previous: [Int32: FMUsageLedger.Counters]? = nil
            FMUsageLedger.record(ok: true, ms: 40)
            _ = FMUsageLedger.drain(previous: &previous)

            FMUsageLedger.record(ok: true, ms: 10)
            let delta = FMUsageLedger.drain(previous: &previous)
            XCTAssertEqual(delta?.calls, 1)
            XCTAssertEqual(delta?.totalMs, 10)
            XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path),
                         "decode 失敗は reap 対象ではない(dead pid とは別経路)")
        }
    }

    /// 死んだ pid の控えだけが消える(生きている控えは残す)。掃除が無いとファイルが際限なく溜まる
    func testReapDeadRemovesOnlyDeadEntries() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let livePID = ProcessInfo.processInfo.processIdentifier
            try writeRawEntry(pid: deadPID, calls: 3, failures: 0, totalMs: 300)
            try writeRawEntry(pid: livePID, calls: 4, failures: 0, totalMs: 400)

            FMUsageLedger.reapDead(in: dir)

            XCTAssertFalse(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("\(deadPID).json").path), "死んだ pid は消える")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("\(livePID).json").path), "生きている pid は残す")
        }
    }

    private func writeRawEntry(pid: Int32, calls: Int, failures: Int, totalMs: Int) throws {
        let json = """
        {"pid":\(pid),"calls":\(calls),"failures":\(failures),"totalMs":\(totalMs),"updatedAt":0}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
    }
}
