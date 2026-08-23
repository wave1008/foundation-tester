import FTCore
import XCTest

/// 離脱には証拠(streak の間に別レーンが通った)を要求する(WorkerCircuitBreaker の冒頭)
final class WorkerCircuitBreakerTests: XCTestCase {

    func testBelowThresholdKeeps() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .keep)
        XCTAssertEqual(b.consecutiveFailures, 2)
    }

    /// 1レーンだけ不調(他レーンは通っている)= 従来どおり離脱
    func testTripsWhenAnotherLanePassedDuringTheStreak() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 6), .keep)      // 他レーンが1本通った
        XCTAssertEqual(b.recordFailure(runPasses: 6), .trip(consecutive: 3))
    }

    /// 全レーンが同時に落ちている(誰も通らない)= 離脱しない。言うのは streak で1回だけ
    func testHeldWhenNobodyPassedSinceTheStreakBegan() {
        var b = WorkerCircuitBreaker(threshold: 3)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 5), .held(consecutive: 3, announce: true))
        XCTAssertEqual(b.recordFailure(runPasses: 5), .held(consecutive: 4, announce: false))
    }

    /// 保留中に他レーンが通ったら、次の失敗で離脱する(証拠が後から揃う)
    func testHeldThenTripsOnceEvidenceArrives() {
        var b = WorkerCircuitBreaker(threshold: 3)
        _ = b.recordFailure(runPasses: 0)
        _ = b.recordFailure(runPasses: 0)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .held(consecutive: 3, announce: true))
        XCTAssertEqual(b.recordFailure(runPasses: 1), .trip(consecutive: 4))
    }

    /// 自レーンの通過は streak を切り、通過数の基準も取り直す(streak 前の他レーンの通過は証拠にしない)
    func testPassResetsTheStreakAndTheBaseline() {
        var b = WorkerCircuitBreaker(threshold: 3)
        _ = b.recordFailure(runPasses: 0)
        _ = b.recordFailure(runPasses: 0)
        b.recordPass()
        XCTAssertEqual(b.consecutiveFailures, 0)
        // streak 前に他レーンが 3 本通っていても、新しい streak の間に誰も通らなければ held
        XCTAssertEqual(b.recordFailure(runPasses: 4), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .keep)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .held(consecutive: 3, announce: true))
        // 新しい streak では改めて1回だけ言う
        b.recordPass()
        _ = b.recordFailure(runPasses: 4); _ = b.recordFailure(runPasses: 4)
        XCTAssertEqual(b.recordFailure(runPasses: 4), .held(consecutive: 3, announce: true))
    }

    func testThresholdOfOneTripsOnTheFirstFailureOnlyWithEvidence() {
        var b = WorkerCircuitBreaker(threshold: 1)
        XCTAssertEqual(b.recordFailure(runPasses: 0), .held(consecutive: 1, announce: true))
        var c = WorkerCircuitBreaker(threshold: 1)
        _ = c.recordFailure(runPasses: 0)
        XCTAssertEqual(c.recordFailure(runPasses: 1), .trip(consecutive: 2))
    }
}
