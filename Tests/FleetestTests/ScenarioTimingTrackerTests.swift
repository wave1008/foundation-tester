// run の所要時間の集計。実行後に出る「⏱ トータル / テスト実時間 / シナリオ合計」の元になる。
//
// 並列実行では「テスト実時間(最初の開始〜最後の終了の壁時計)」と「シナリオ合計(各シナリオの
// 所要の総和)」が意図的に別物で、両者の比が実質的な並列度を表す。ここを取り違えると
// 性能判断の土台が崩れる(docs/performance-tuning.md の計測はこの値を読む)。

import XCTest
import FTCore
@testable import fleetest

final class ScenarioTimingTrackerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id,
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

    /// 開始・終了とも送られた時刻(flowStartedAt / flowEndedAt)で数える。終了が境目の表示の確認まで保留された回も、
    /// 確認・回復の時間がシナリオ合計・レーンの busy・テスト実時間に入らない
    func testHeldFinishIsCountedAtItsRealEndTime() {
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        tracker.record(.flowStartedAt(worker: "ios:1", flowURL: a.url, at: base), at: base)
        tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url, flowName: a.info.id, isDirty: false), at: base)
        tracker.record(.flowEndedAt(worker: "ios:1", flowURL: a.url, at: base.addingTimeInterval(10)),
                       at: base.addingTimeInterval(70))
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true, reportURL: nil, fm: nil,
                                     notApplicableReason: nil), at: base.addingTimeInterval(70))
        XCTAssertEqual(tracker.scenarioTotalSeconds ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(tracker.testSeconds ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(tracker.laneUtilizations.first?.busySeconds ?? 0, 10, accuracy: 0.001)
    }

    /// 読み手が開始イベントを遅れて受け取っても、送られた時刻で数えるので所要は負にならない
    func testLateReceiptOfTheStartDoesNotMakeTheDurationNegative() {
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        tracker.record(.flowStartedAt(worker: "ios:1", flowURL: a.url, at: base), at: base.addingTimeInterval(20))
        tracker.record(.flowStarted(worker: "ios:1", flowURL: a.url, flowName: a.info.id, isDirty: false),
                       at: base.addingTimeInterval(20))
        tracker.record(.flowEndedAt(worker: "ios:1", flowURL: a.url, at: base.addingTimeInterval(10)),
                       at: base.addingTimeInterval(20))
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true, reportURL: nil, fm: nil,
                                     notApplicableReason: nil), at: base.addingTimeInterval(20))
        XCTAssertEqual(tracker.scenarioTotalSeconds ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(tracker.testSeconds ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(tracker.laneUtilizations.first?.busySeconds ?? -1, 10, accuracy: 0.001)
    }

    /// broadcast: 同じ flowURL を 2 つのワーカーが走らせ、送られた時刻のイベントが交錯しても、それぞれの時刻で数える
    func testBroadcastKeepsEachWorkersTimesApart() {
        var tracker = ScenarioTimingTracker()
        let a = item("A.S0010")
        for worker in ["ios:1", "ios:2"] {
            tracker.record(.flowStartedAt(worker: worker, flowURL: a.url, at: base), at: base)
            tracker.record(.flowStarted(worker: worker, flowURL: a.url, flowName: a.info.id, isDirty: false), at: base)
        }
        tracker.record(.flowEndedAt(worker: "ios:1", flowURL: a.url, at: base.addingTimeInterval(10)),
                       at: base.addingTimeInterval(70))
        tracker.record(.flowEndedAt(worker: "ios:2", flowURL: a.url, at: base.addingTimeInterval(20)),
                       at: base.addingTimeInterval(70))
        for worker in ["ios:1", "ios:2"] {
            tracker.record(.flowFinished(worker: worker, flowURL: a.url, passed: true, reportURL: nil, fm: nil,
                                         notApplicableReason: nil), at: base.addingTimeInterval(70))
        }
        XCTAssertEqual(tracker.testSeconds ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(tracker.scenarioTotalSeconds ?? 0, 30, accuracy: 0.001, "10 + 20")
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
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))
        tracker.record(.flowFinished(worker: "ios:2", flowURL: b.url, passed: true,
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))

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
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))
        // 開始を観測していないので「1本も計測していない」= nil(0 秒ではない)
        XCTAssertNil(tracker.scenarioTotalSeconds)
        XCTAssertNil(tracker.testSeconds)
    }

    func testUnrelatedEventsDoNotAffectTiming() {
        var tracker = ScenarioTimingTracker()
        tracker.record(.runStarted(total: 1, workerLabels: ["ios:1"]))
        tracker.record(.workerReady(worker: "ios:1"))
        tracker.record(.runFinished(passed: 1, failed: 0, skipped: 0))
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
                                         reportURL: nil, fm: nil,
                                     notApplicableReason: nil))
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
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))

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
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))
        let afterFirst = try? XCTUnwrap(tracker.scenarioTotalSeconds)

        Thread.sleep(forTimeInterval: 0.08)
        tracker.record(.flowFinished(worker: "ios:1", flowURL: a.url, passed: true,
                                     reportURL: nil, fm: nil,
                                     notApplicableReason: nil))

        XCTAssertEqual(tracker.scenarioTotalSeconds ?? 0, afterFirst ?? 0, accuracy: 0.001,
                       "開始を伴わない2回目の終了は加算しない")
    }
}
