// FMLoadGenerator.summarize は FM を呼ばない純粋関数(サンプル配列 → Summary)。
// FM 呼び出し自体は環境依存(Apple Intelligence の有無)なので、ここでは集計ロジックだけを固定する。

import XCTest
@testable import FTFoundationModels

final class FMLoadGeneratorSummaryTests: XCTestCase {

    private func sample(_ ms: Double, ok: Bool = true, error: String? = nil) -> FMLoadGenerator.Sample {
        FMLoadGenerator.Sample(ms: ms, ok: ok, error: error)
    }

    func testEmptySamplesYieldZeroSummary() {
        let summary = FMLoadGenerator.summarize(samples: [], elapsedSeconds: 30)
        XCTAssertEqual(summary.calls, 0)
        XCTAssertEqual(summary.failures, 0)
        XCTAssertEqual(summary.p50Ms, 0)
        XCTAssertEqual(summary.maxMs, 0)
        XCTAssertEqual(summary.throughputPerSecond, 0)
        XCTAssertNil(summary.firstError)
    }

    func testSingleSample() {
        let summary = FMLoadGenerator.summarize(samples: [sample(1200)], elapsedSeconds: 1.2)
        XCTAssertEqual(summary.calls, 1)
        XCTAssertEqual(summary.failures, 0)
        XCTAssertEqual(summary.p50Ms, 1200)
        XCTAssertEqual(summary.maxMs, 1200)
        XCTAssertEqual(summary.throughputPerSecond, 1.0 / 1.2, accuracy: 0.0001)
    }

    /// 偶数個: index = count/2(上側中央値)。FMHealth.percentileMs と同じ規律
    func testEvenCountPicksUpperMiddle() {
        let samples = [sample(400), sample(100), sample(300), sample(200)]
        let summary = FMLoadGenerator.summarize(samples: samples, elapsedSeconds: 4)
        XCTAssertEqual(summary.p50Ms, 300)
        XCTAssertEqual(summary.maxMs, 400)
    }

    func testOddCountPicksMiddle() {
        let samples = [sample(300), sample(100), sample(200)]
        let summary = FMLoadGenerator.summarize(samples: samples, elapsedSeconds: 3)
        XCTAssertEqual(summary.p50Ms, 200)
        XCTAssertEqual(summary.maxMs, 300)
    }

    func testFailuresCountedAndFirstErrorIsFirstFailingSample() {
        let samples = [
            sample(100, ok: true),
            sample(200, ok: false, error: "first failure"),
            sample(300, ok: false, error: "second failure"),
        ]
        let summary = FMLoadGenerator.summarize(samples: samples, elapsedSeconds: 3)
        XCTAssertEqual(summary.calls, 3)
        XCTAssertEqual(summary.failures, 2)
        XCTAssertEqual(summary.firstError, "first failure")
    }

    func testThroughputIsCallsDividedByElapsed() {
        let samples = (0..<10).map { _ in sample(1000) }
        let summary = FMLoadGenerator.summarize(samples: samples, elapsedSeconds: 5)
        XCTAssertEqual(summary.throughputPerSecond, 2.0, accuracy: 0.0001)
    }

    /// elapsedSeconds<=0 は割り算せず0を返す(呼び出し側が deadline 直後に集計しても NaN/inf にしない)
    func testZeroElapsedSecondsYieldsZeroThroughput() {
        let summary = FMLoadGenerator.summarize(samples: [sample(100)], elapsedSeconds: 0)
        XCTAssertEqual(summary.throughputPerSecond, 0)
    }
}
