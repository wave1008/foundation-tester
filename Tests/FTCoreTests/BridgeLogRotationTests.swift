// BridgeLogRotation.candidate(純粋関数)の境界を固定する。期待値は production の定数を参照せず
// リテラルで書く(RetentionSweepTests と同じ規律)。

import XCTest
@testable import FTCore

final class BridgeLogRotationTests: XCTestCase {

    private func session(_ id: String, bytes: Int64, minutesAgo: Int,
                         guarded: Bool = false) -> RetentionSweep.Session {
        RetentionSweep.Session(
            id: id, bytes: bytes,
            newestModified: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
            paths: [URL(fileURLWithPath: "/tmp/\(id)")], guarded: guarded)
    }

    func testUnderTheCapReturnsNil() {
        let sessions = [session("bridge-8123-1", bytes: 10, minutesAgo: 1, guarded: true)]
        XCTAssertNil(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100))
    }

    /// 上限超過だが guarded は無い(掃除すれば済む)→ 建て直す必要が無い
    func testOverCapWithNoGuardedSessionsReturnsNil() {
        let sessions = [session("bridge-8123-1", bytes: 150, minutesAgo: 1, guarded: false)]
        XCTAssertNil(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100))
    }

    /// guarded だけで超過 → その guarded を返す
    func testGuardedAloneOverCapReturnsTheGuardedSession() {
        let sessions = [session("bridge-8123-1", bytes: 150, minutesAgo: 1, guarded: true)]
        XCTAssertEqual(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100)?.id, "bridge-8123-1")
    }

    /// guarded が複数あれば bytes 最大のものを選ぶ(消しても超過が解消しない小さい束を選ばない)
    func testPicksTheLargestGuardedSessionAmongMultiple() {
        let sessions = [
            session("bridge-8123-1", bytes: 60, minutesAgo: 1, guarded: true),
            session("bridge-8124-1", bytes: 90, minutesAgo: 2, guarded: true),
        ]
        XCTAssertEqual(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100)?.id, "bridge-8124-1")
    }

    /// 非 guarded(古い run のぶん等)が混ざっていても guarded だけを候補にする
    func testIgnoresNonGuardedSessionsWhenPickingTheCandidate() {
        let sessions = [
            session("bridge-8123-1", bytes: 200, minutesAgo: 1, guarded: false),
            session("bridge-8124-1", bytes: 95, minutesAgo: 2, guarded: true),
        ]
        XCTAssertEqual(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100)?.id, "bridge-8124-1")
    }

    /// 同点は id 昇順(run ごとに結果が変わらない。RetentionSweep.plan の同着規則と同じ向き)
    func testTiesAreBrokenByIdAscending() {
        let sessions = [
            session("bridge-8124-1", bytes: 90, minutesAgo: 1, guarded: true),
            session("bridge-8123-1", bytes: 90, minutesAgo: 2, guarded: true),
        ]
        XCTAssertEqual(BridgeLogRotation.candidate(sessions: sessions, maxBytes: 100)?.id, "bridge-8123-1")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(BridgeLogRotation.candidate(sessions: [], maxBytes: 100))
    }
}
