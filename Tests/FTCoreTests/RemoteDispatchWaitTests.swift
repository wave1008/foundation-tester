// dispatch.lock の待機列を呼ぶ側の純粋ロジック(Sources/FTRemote/RemoteDispatchWait.swift)。
// ログの文言は**完全一致**で固定する —— 同じ値から NDJSON イベントも組み立てるので、
// 数字の意味(position / total / 経過 / 上限)がここでずれると端末と拡張で食い違う。

import Foundation
import XCTest
import FTRemote

final class RemoteDispatchResolveTicketTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    /// **環境にあるチケットをそのまま使う**(親が採った時刻を全機械で共有する)。
    /// issuer / runGroup / pid の引数は使われない
    func testInheritsTheTicketFromTheEnvironment() {
        let inherited = DispatchTicket(requestedAtMillis: 1_700_000_000_000,
                                       issuer: "ci", group: "fleet-7")
        let resolved = RemoteDispatchQueue.resolveTicket(
            environment: [DispatchTicket.environmentKey: inherited.environmentValue],
            issuer: "someone-else", runGroup: "another-group", pid: 4242, now: now)
        XCTAssertEqual(resolved, inherited)
    }

    /// 壊れた値は黙って落とさず、自分で採る(失うのは順番だけ)
    func testFallsBackToAFreshTicketWhenTheEnvironmentValueIsMalformed() {
        let resolved = RemoteDispatchQueue.resolveTicket(
            environment: [DispatchTicket.environmentKey: "not-a-ticket"],
            issuer: "ci", runGroup: "fleet-7", pid: 4242, now: now)
        XCTAssertEqual(resolved, DispatchTicket(requestedAtMillis: 1_755_000_000_000,
                                                issuer: "ci", group: "fleet-7"))
    }

    func testUsesTheRunGroupWhenThereIsNoInheritedTicket() {
        let resolved = RemoteDispatchQueue.resolveTicket(
            environment: [:], issuer: "ci", runGroup: "fleet-7", pid: 4242, now: now)
        XCTAssertEqual(resolved.group, "fleet-7")
        XCTAssertEqual(resolved.requestedAtMillis, 1_755_000_000_000)
    }

    /// runGroup の無い単発の run は pid で区別する
    func testFallsBackToThePIDWhenThereIsNoRunGroup() {
        let resolved = RemoteDispatchQueue.resolveTicket(
            environment: [:], issuer: "ci", runGroup: nil, pid: 4242, now: now)
        XCTAssertEqual(resolved.group, "4242")
    }
}

final class DispatchWaitStatusTests: XCTestCase {

    private static let holderInfo = RemoteDispatchLockInfo(
        issuerHost: "mbp", pid: 1, acquiredAt: "2026-09-21T00:00:00Z", issuer: "ci")

    private func status(position: Int = 2, total: Int = 3,
                        holder: RemoteDispatchLockInfo? = DispatchWaitStatusTests.holderInfo,
                        elapsedSeconds: Int = 0, limitSeconds: Int? = 600) -> DispatchWaitStatus {
        DispatchWaitStatus(target: "m1max.local", position: position, total: total, holder: holder,
                           elapsedSeconds: elapsedSeconds, limitSeconds: limitSeconds)
    }

    func testQueuedLineExactText() {
        XCTAssertEqual(
            status().queuedLine,
            "==> queued for the dispatch lock on m1max.local — position 2 of 3,"
            + " started by ci (from mbp, pid 1) at 2026-09-21T00:00:00Z — waiting up to 600s")
    }

    /// 保持者が読めなかったときは**保持者の句ごと落とす** —— 「holder unknown」と書くと、
    /// 実際には誰も掴んでいない(自分の前に並んでいる人が居るだけ)ときに占有を断定してしまう
    func testQueuedLineOmitsTheHolderWhenItCouldNotBeRead() {
        XCTAssertEqual(
            status(holder: nil).queuedLine,
            "==> queued for the dispatch lock on m1max.local — position 2 of 3 — waiting up to 600s")
    }

    func testStillQueuedLineExactText() {
        XCTAssertEqual(status(elapsedSeconds: 60).stillQueuedLine,
                       "==> still queued on m1max.local (position 2 of 3, 60s of 600s)")
    }

    /// `--wait-lock` が無ければ上限の句を出さない(存在しない数字を書かない)
    func testLinesOmitTheLimitWhenThereIsNone() {
        XCTAssertEqual(
            status(limitSeconds: nil).queuedLine,
            "==> queued for the dispatch lock on m1max.local — position 2 of 3,"
            + " started by ci (from mbp, pid 1) at 2026-09-21T00:00:00Z")
        XCTAssertEqual(status(elapsedSeconds: 60, limitSeconds: nil).stillQueuedLine,
                       "==> still queued on m1max.local (position 2 of 3, 60s)")
    }

    func testAheadCountIsThePositionMinusOne() {
        XCTAssertEqual(status(position: 1).aheadCount, 0)
        XCTAssertEqual(status(position: 3).aheadCount, 2)
    }

    /// 足すものが無ければ**空文字** = 従来の heldMessage と1バイトも変わらない
    func testRefusalSuffixIsEmptyWhenNobodyIsAheadAndNothingWasWaited() {
        XCTAssertEqual(status(position: 1, total: 1).refusalSuffix, "")
    }

    func testRefusalSuffixNamesTheQueueAndTheWait() {
        XCTAssertEqual(status(position: 3).refusalSuffix, " (2 ahead in the queue)")
        XCTAssertEqual(status(position: 1, elapsedSeconds: 600).refusalSuffix, " (waited 600s)")
        XCTAssertEqual(status(position: 3, elapsedSeconds: 600).refusalSuffix,
                       " (2 ahead in the queue, waited 600s)")
    }

    /// 保持者を読めたときは従来の heldMessage(ロックの文言)+ 待機列の句
    func testRefusalKeepsTheHeldMessageWhenTheHolderIsKnown() {
        let message = status(position: 3).refusalMessage
        XCTAssertTrue(message.hasPrefix("another dispatch is already running on this remote host"),
                      message)
        XCTAssertTrue(message.hasSuffix(" (2 ahead in the queue)"), message)
    }

    /// **保持者が読めず、自分の前に並んでいる人が居るだけなら「走っている」と言わない**
    /// (その人もまだ待っているかもしれない = 「不明」を「占有」に倒さない)
    func testRefusalDoesNotClaimARunIsRunningWhenOnlyTheQueueIsAhead() {
        XCTAssertEqual(
            status(position: 3, holder: nil, limitSeconds: nil).refusalMessage,
            "2 earlier request(s) are queued ahead of yours for the dispatch lock on m1max.local"
            + " — wait for them to finish, or pass --wait-lock <seconds> to wait your turn")
        XCTAssertEqual(
            status(position: 3, holder: nil, elapsedSeconds: 600).refusalMessage,
            "2 earlier request(s) are queued ahead of yours for the dispatch lock on m1max.local"
            + " — wait for them to finish (waited 600s)")
    }

    /// 自分が先頭なのに取れなかった(= 誰かが掴んでいるが控えが読めない)ときは従来どおり
    /// ロックの定型文へ倒す —— こちらは「並んでいる人が居るだけ」ではない
    func testRefusalFallsBackToTheLockMessageWhenWeAreFirst() {
        let message = status(position: 1, total: 1, holder: nil).refusalMessage
        XCTAssertTrue(message.hasPrefix("another dispatch is already running on this remote host"),
                      message)
        XCTAssertTrue(message.contains("holder unknown"), message)
    }
}
