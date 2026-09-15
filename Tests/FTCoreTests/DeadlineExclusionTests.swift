// `DeadlineExclusion`: 「ツールの都合で待った時間」(今のところ RegionText.awaitPrewarm の待ちだけ)
// を締め切りの計算から差し引くための帳簿。完了分の合計・進行中の経過・observer への通知を確かめる。

import XCTest
@testable import FTCore

final class DeadlineExclusionTests: XCTestCase {

    override func tearDown() {
        DeadlineExclusion.observer = nil
        super.tearDown()
    }

    func testExcludedIsZeroWhenNothingBegan() {
        let snap = DeadlineExclusion.snapshot()
        XCTAssertEqual(DeadlineExclusion.excluded(since: snap), .zero)
    }

    func testACompletedWindowCountsTowardExcluded() async {
        let snap = DeadlineExclusion.snapshot()
        let token = DeadlineExclusion.begin(cap: .seconds(2))
        try? await Task.sleep(for: .milliseconds(120))
        DeadlineExclusion.end(token)
        let excluded = DeadlineExclusion.excluded(since: snap)
        XCTAssertGreaterThanOrEqual(excluded, .milliseconds(100), "完了した窓を数えていない(実測 \(excluded))")
        XCTAssertLessThan(excluded, .seconds(1))
    }

    /// **進行中でも(end を待たず)** excluded に足される —— FTSync.run はタイムアウトのたびに
    /// この値を見て「あとどれだけ延ばすか」を決めるので、end を待つと締め切りに間に合わない
    func testAnInProgressWindowCountsBeforeEnding() async {
        let snap = DeadlineExclusion.snapshot()
        let token = DeadlineExclusion.begin(cap: .seconds(5))
        try? await Task.sleep(for: .milliseconds(120))
        let excluded = DeadlineExclusion.excluded(since: snap)
        XCTAssertGreaterThanOrEqual(excluded, .milliseconds(100), "進行中の窓を数えていない(実測 \(excluded))")
        DeadlineExclusion.end(token)
    }

    func testMultipleWindowsSum() async {
        let snap = DeadlineExclusion.snapshot()
        let token1 = DeadlineExclusion.begin(cap: .seconds(1))
        try? await Task.sleep(for: .milliseconds(80))
        DeadlineExclusion.end(token1)
        let token2 = DeadlineExclusion.begin(cap: .seconds(1))
        try? await Task.sleep(for: .milliseconds(80))
        DeadlineExclusion.end(token2)
        let excluded = DeadlineExclusion.excluded(since: snap)
        XCTAssertGreaterThanOrEqual(excluded, .milliseconds(150), "複数回の窓を合計していない(実測 \(excluded))")
    }

    /// snapshot より前に完了した窓は数えない(delta ベース)
    func testWindowsBeforeTheSnapshotAreNotCounted() async {
        let token = DeadlineExclusion.begin(cap: .seconds(1))
        try? await Task.sleep(for: .milliseconds(80))
        DeadlineExclusion.end(token)
        let snap = DeadlineExclusion.snapshot()  // ここより前の分は数えない
        XCTAssertEqual(DeadlineExclusion.excluded(since: snap), .zero)
    }

    func testObserverReceivesBeganThenEndedWithMeasuredDuration() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [DeadlineExclusion.Change] = []
            func append(_ change: DeadlineExclusion.Change) { lock.lock(); stored.append(change); lock.unlock() }
            var changes: [DeadlineExclusion.Change] { lock.lock(); defer { lock.unlock() }; return stored }
        }
        let box = Box()
        DeadlineExclusion.observer = { box.append($0) }

        let token = DeadlineExclusion.begin(cap: .milliseconds(500))
        try? await Task.sleep(for: .milliseconds(30))
        DeadlineExclusion.end(token)

        let changes = box.changes
        XCTAssertEqual(changes.count, 2)
        guard case .began(let capMs) = changes.first else { return XCTFail("began が先頭にない: \(changes)") }
        XCTAssertEqual(capMs, 500)
        guard case .ended(let ms) = changes.last else { return XCTFail("ended が末尾にない: \(changes)") }
        XCTAssertGreaterThanOrEqual(ms, 15, "実測が短すぎる(cap をそのまま返している疑い)")
    }
}
