// run の所要時間の集計。実行後に出る「⏱ トータル / テスト実時間 / シナリオ合計」の元になる。
//
// 並列実行では「テスト実時間(最初の開始〜最後の終了の壁時計)」と「シナリオ合計(各シナリオの
// 所要の総和)」が意図的に別物で、両者の比が実質的な並列度を表す。ここを取り違えると
// 性能判断の土台が崩れる(docs/performance-tuning.md の計測はこの値を読む)。

import XCTest
import FTCore
@testable import ftester

final class ScenarioTimingTrackerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp",
                                           platform: nil, deleted: false))
    }

    // MARK: - 逐次(明示的な時刻)

    func testSequentialAccumulatesEachScenarioAndSpansWallClock() {
        var tracker = ScenarioTimingTracker()
        tracker.recordSequential(start: base, finish: base.addingTimeInterval(10))
        tracker.recordSequential(start: base.addingTimeInterval(10),
                                 finish: base.addingTimeInterval(25))

        XCTAssertEqual(tracker.testSeconds ?? 0, 25, accuracy: 0.001, "最初の開始〜最後の終了")
        XCTAssertEqual(tracker.scenarioTotalSeconds ?? 0, 25, accuracy: 0.001, "所要の総和")
    }

    func testSequentialKeepsEarliestStartAndLatestFinish() {
        var tracker = ScenarioTimingTracker()
        tracker.recordSequential(start: base.addingTimeInterval(5),
                                 finish: base.addingTimeInterval(20))
        // 後から早い開始が来ても firstStart は上書きしない(逐次実行では順序が保証される)
        tracker.recordSequential(start: base.addingTimeInterval(20),
                                 finish: base.addingTimeInterval(30))
        XCTAssertEqual(tracker.testSeconds ?? 0, 25, accuracy: 0.001)
    }

    func testEmptyTrackerReportsNilNotZero() {
        // 0 と「1本も走っていない」は別。レポートは値なしとして扱う必要がある
        let tracker = ScenarioTimingTracker()
        XCTAssertNil(tracker.testSeconds)
        XCTAssertNil(tracker.scenarioTotalSeconds)
    }

    // MARK: - 並列(RunEvent 経由)

    func testParallelScenarioTotalExceedsWallClock() {
        // 2本を重ねて走らせると シナリオ合計 > テスト実時間 になる(= 並列が効いている)
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010"), b = item("B.S0010")

        tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url, flowName: a.info.id, isDirty: false))
        tracker.record(.flowStarted(worker: "ios:2", flowURL: b.url, flowName: b.info.id, isDirty: false))
        Thread.sleep(forTimeInterval: 0.05)
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true,
                                     triage: nil, reportURL: nil, fm: nil))
        tracker.record(.flowFinished(worker: "ios:2", flowURL: b.url, passed: true,
                                     triage: nil, reportURL: nil, fm: nil))

        let wall = try? XCTUnwrap(tracker.testSeconds)
        let total = try? XCTUnwrap(tracker.scenarioTotalSeconds)
        XCTAssertNotNil(wall)
        XCTAssertNotNil(total)
        XCTAssertGreaterThan(total ?? 0, (wall ?? 0) * 1.5,
                             "重なって走った2本の合計は壁時計より明確に大きくなるはず")
    }

    func testFinishWithoutStartIsIgnored() {
        // 振り直し等で開始を観測していない終了が来ても、負の所要を足し込まない
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: false,
                                     triage: nil, reportURL: nil, fm: nil))
        // 開始を観測していないので「1本も計測していない」= nil(0 秒ではない)
        XCTAssertNil(tracker.scenarioTotalSeconds)
        XCTAssertNil(tracker.testSeconds)
    }

    func testUnrelatedEventsDoNotAffectTiming() {
        var tracker = ScenarioTimingTracker()
        tracker.record(.runStarted(total: 1, workerLabels: ["ios:1"]))
        tracker.record(.workerReady(worker: "ios:1"))
        tracker.record(.runFinished(passed: 1, failed: 0))
        XCTAssertNil(tracker.testSeconds, "シナリオが走っていなければ計測なし")
    }

    func testSameScenarioCanBeMeasuredAgainAfterRequeue() {
        // 振り直しで同じ flowURL が再度 started → finished する。2回目も計上される
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        for _ in 0..<2 {
            tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url,
                                        flowName: a.info.id, isDirty: false))
            tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true,
                                         triage: nil, reportURL: nil, fm: nil))
        }
        XCTAssertNotNil(tracker.scenarioTotalSeconds)
    }

    func testWallClockSpansFromTheFirstStartNotTheLatest() {
        // 2本目の開始で firstStart を上書きすると、テスト実時間が実際より短く出る
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010"), b = item("B.S0010")
        tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url, flowName: a.info.id, isDirty: false))
        Thread.sleep(forTimeInterval: 0.08)
        tracker.record(.flowStarted(worker: "ios:2", flowURL: b.url, flowName: b.info.id, isDirty: false))
        Thread.sleep(forTimeInterval: 0.08)
        tracker.record(.flowFinished(worker: "ios:2", flowURL: b.url, passed: true,
                                     triage: nil, reportURL: nil, fm: nil))

        XCTAssertGreaterThan(tracker.testSeconds ?? 0, 0.14,
                             "1本目の開始から数えること(2本目で上書きすると約半分になる)")
    }

    func testDuplicateFinishIsNotCountedTwice() {
        // 開始記録を消さないと、同じ flowURL の終了が2回来たとき所要が二重に積まれる
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url, flowName: a.info.id, isDirty: false))
        Thread.sleep(forTimeInterval: 0.08)
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true,
                                     triage: nil, reportURL: nil, fm: nil))
        let afterFirst = try? XCTUnwrap(tracker.scenarioTotalSeconds)

        Thread.sleep(forTimeInterval: 0.08)
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true,
                                     triage: nil, reportURL: nil, fm: nil))

        XCTAssertEqual(tracker.scenarioTotalSeconds ?? 0, afterFirst ?? 0, accuracy: 0.001,
                       "開始を伴わない2回目の終了は加算しない")
    }
}
