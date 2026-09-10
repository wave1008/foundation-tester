// RetentionSweep.plan(純粋関数)の境界を固定する。期待値は production の定数を参照せず
// リテラルで書く(定数を流用すると、定数を変えた変異がテストごと一緒に動いて素通しする)。

import XCTest
@testable import FTCore

final class RetentionSweepTests: XCTestCase {

    private func session(_ id: String, bytes: Int64, minutesAgo: Int,
                         guarded: Bool = false) -> RetentionSweep.Session {
        RetentionSweep.Session(
            id: id, bytes: bytes,
            newestModified: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
            paths: [URL(fileURLWithPath: "/tmp/\(id)")], guarded: guarded)
    }

    // MARK: - 境界(ちょうど上限 / 上限−1 / 上限+1)

    func testExactlyAtTheCapDeletesNothing() {
        let sessions = [session("a", bytes: 60, minutesAgo: 1),
                        session("b", bytes: 40, minutesAgo: 2)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete, [])
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertEqual(plan.keptBytes, 100)
        XCTAssertFalse(plan.overCapAfterGuards)
    }

    func testOneByteUnderTheCapDeletesNothing() {
        let sessions = [session("a", bytes: 60, minutesAgo: 1),
                        session("b", bytes: 39, minutesAgo: 2)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete, [])
        XCTAssertEqual(plan.keptBytes, 99)
    }

    /// 上限を超えたセッション**自身**から消える(超えた「次」からではない)
    func testOneByteOverTheCapDeletesTheSessionThatCrossedIt() {
        let sessions = [session("a", bytes: 60, minutesAgo: 1),
                        session("b", bytes: 41, minutesAgo: 2)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["b"])
        XCTAssertEqual(plan.freedBytes, 41)
        XCTAssertEqual(plan.keptBytes, 60)
    }

    func testEverythingAfterTheCrossingSessionIsDeletedToo() {
        let sessions = [session("a", bytes: 100, minutesAgo: 1),
                        session("b", bytes: 1, minutesAgo: 2),
                        session("c", bytes: 5, minutesAgo: 3)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["b", "c"])
        XCTAssertEqual(plan.freedBytes, 6)
        XCTAssertEqual(plan.keptBytes, 100)
    }

    // MARK: - guarded

    func testGuardedSessionsAreNeverDeleted() {
        let sessions = [session("live", bytes: 80, minutesAgo: 5, guarded: true),
                        session("old", bytes: 30, minutesAgo: 10)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["old"])
        XCTAssertEqual(plan.keptBytes, 80)
    }

    /// guarded のバイト数も累計に入る = 消せないものが容量を食っている事実を隠さない。
    /// guarded を数えなければ 60+30=90 で上限内になり "old" は残るはずだった
    func testGuardedBytesCountTowardTheRunningTotal() {
        let sessions = [session("live", bytes: 60, minutesAgo: 1, guarded: true),
                        session("newer", bytes: 30, minutesAgo: 2),
                        session("old", bytes: 30, minutesAgo: 3)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["old"])
        XCTAssertEqual(plan.keptBytes, 90)
    }

    func testAllGuardedDeletesNothing() {
        let sessions = [session("a", bytes: 10, minutesAgo: 1, guarded: true),
                        session("b", bytes: 10, minutesAgo: 2, guarded: true)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete, [])
        XCTAssertEqual(plan.keptBytes, 20)
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertFalse(plan.overCapAfterGuards)
    }

    /// guarded だけで上限を超えていても**消せるものは全部消す**。上限に届かないことを理由に
    /// 手を止めると、進行中の run が上限より大きい添付を抱えているだけで無関係な分が残り続ける
    func testGuardedAloneOverTheCapStillDeletesEverythingElse() {
        let sessions = [session("live", bytes: 150, minutesAgo: 1, guarded: true),
                        session("old", bytes: 40, minutesAgo: 9)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertTrue(plan.overCapAfterGuards)
        XCTAssertEqual(plan.delete.map(\.id), ["old"])
        XCTAssertEqual(plan.freedBytes, 40)
        XCTAssertEqual(plan.keptBytes, 150)
    }

    // MARK: - maxBytes <= 0(保持しない)

    func testZeroCapDeletesEverythingThatIsNotGuarded() {
        let sessions = [session("live", bytes: 10, minutesAgo: 1, guarded: true),
                        session("a", bytes: 5, minutesAgo: 2),
                        session("b", bytes: 7, minutesAgo: 3)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 0)
        XCTAssertEqual(plan.delete.map(\.id), ["a", "b"])
        XCTAssertEqual(plan.freedBytes, 12)
        XCTAssertEqual(plan.keptBytes, 10)
        // guarded が残るので上限 0 には収まらない —— 呼び出し側が警告できるように立てる
        XCTAssertTrue(plan.overCapAfterGuards)
    }

    func testZeroCapWithNoGuardedSessionsIsNotReportedAsOverCap() {
        let plan = RetentionSweep.plan(sessions: [session("a", bytes: 5, minutesAgo: 1)],
                                       maxBytes: 0)
        XCTAssertEqual(plan.delete.map(\.id), ["a"])
        XCTAssertFalse(plan.overCapAfterGuards)
    }

    // MARK: - 空入力・並び

    func testEmptyInput() {
        let plan = RetentionSweep.plan(sessions: [], maxBytes: 100)
        XCTAssertEqual(plan.delete, [])
        XCTAssertEqual(plan.keptBytes, 0)
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertFalse(plan.overCapAfterGuards)
    }

    func testEmptyInputWithZeroCap() {
        let plan = RetentionSweep.plan(sessions: [], maxBytes: 0)
        XCTAssertEqual(plan.delete, [])
        XCTAssertFalse(plan.overCapAfterGuards)
    }

    /// 新しい順に積む(入力順には依存しない)
    func testNewestFirstRegardlessOfInputOrder() {
        let sessions = [session("old", bytes: 60, minutesAgo: 30),
                        session("new", bytes: 60, minutesAgo: 1)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["old"])
    }

    /// 同着は id 昇順(run ごとに結果が変わらない)
    func testTiesAreBrokenByIdAscending() {
        let sessions = [session("b", bytes: 60, minutesAgo: 5),
                        session("a", bytes: 60, minutesAgo: 5)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete.map(\.id), ["b"])
    }

    /// 0 バイトのセッションは上限を超えさせない
    func testZeroByteSessionsDoNotCrossTheCap() {
        let sessions = [session("a", bytes: 100, minutesAgo: 1),
                        session("empty", bytes: 0, minutesAgo: 2)]
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: 100)
        XCTAssertEqual(plan.delete, [])
    }
}
