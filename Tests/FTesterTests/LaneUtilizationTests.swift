// プラットフォーム別レーン稼働の集計と、振り替え助言の判定。
// docs/performance-tuning.md §3.6 の実測値をそのまま再現ケースにしている
// (iOS 5レーン 88〜96% で 185秒 / Android 5レーン 25〜48% で 88秒終了 → 振り替えが効く)。

import XCTest
import FTCore
@testable import ftester

final class LaneUtilizationTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: Double) -> Date { base.addingTimeInterval(offset) }

    private func url(_ id: String) -> URL { ScenarioRunItem.url(for: id) }

    /// worker で id のシナリオを start..finish の間だけ走らせる。
    private func run(_ tracker: inout ScenarioTimingTracker, _ id: String,
                     worker: String, from: Double, to: Double) {
        tracker.record(.flowStarted(worker: worker, flowURL: url(id), flowName: id, isDirty: false),
                       at: at(from))
        tracker.record(.flowFinished(worker: worker, flowURL: url(id), passed: true,
                                     triage: nil, reportURL: nil, fm: nil), at: at(to))
    }

    // MARK: - 集計

    func testFullyBusySingleLaneIsHundredPercent() {
        var tracker = ScenarioTimingTracker()
        run(&tracker, "A", worker: "ios:8123", from: 0, to: 100)

        let stats = tracker.laneUtilizations
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].platform, "ios")
        XCTAssertEqual(stats[0].lanes, 1)
        XCTAssertEqual(stats[0].utilization, 1.0, accuracy: 0.001)
        XCTAssertEqual(stats[0].lastFinishSeconds, 100, accuracy: 0.001)
    }

    func testIdlePlatformShowsLowUtilizationAndEarlyFinish() {
        // §3.6 の形: iOS は最後まで詰まっている / Android は半分の時点で終わる
        var tracker = ScenarioTimingTracker()
        run(&tracker, "iosA", worker: "ios:8123", from: 0, to: 100)
        run(&tracker, "andA", worker: "android:emulator-5554", from: 0, to: 50)

        let stats = tracker.laneUtilizations
        XCTAssertEqual(stats.map(\.platform), ["android", "ios"], "platform 名の昇順")

        let android = stats[0], ios = stats[1]
        XCTAssertEqual(ios.utilization, 1.0, accuracy: 0.001)
        XCTAssertEqual(ios.lastFinishSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(android.utilization, 0.5, accuracy: 0.001, "run 全体の壁時計が分母")
        XCTAssertEqual(android.lastFinishSeconds, 50, accuracy: 0.001)
    }

    func testUtilizationCountsEachLaneSeparately() {
        // 2レーンのうち1本だけが全区間動いた = 稼働 50%
        var tracker = ScenarioTimingTracker()
        run(&tracker, "A", worker: "ios:8123", from: 0, to: 100)
        run(&tracker, "B", worker: "ios:8124", from: 0, to: 50)

        let ios = tracker.laneUtilizations[0]
        XCTAssertEqual(ios.lanes, 2)
        XCTAssertEqual(ios.busySeconds, 150, accuracy: 0.001)
        XCTAssertEqual(ios.utilization, 0.75, accuracy: 0.001, "150 ÷ (2 レーン × 100s)")
    }

    func testRecoveredBridgeWithNewPortIsStillTheSameLane() {
        // iOS の label はブリッジのポートを含み、回復のたびに変わる。同じ台の新旧 label を
        // 別レーンに数えると分母が増えて稼働率が下がって見える(2台が「3 lane(s), 66%」)
        var tracker = ScenarioTimingTracker()
        run(&tracker, "A", worker: "iPhone 17 Pro(iOS 27.0)-02(ios:8123)", from: 0, to: 50)
        run(&tracker, "B", worker: "iPhone 17 Pro(iOS 27.0)-02(ios:8131)", from: 50, to: 100)
        run(&tracker, "C", worker: "iPhone 17 Pro(iOS 27.0)-01(ios:8124)", from: 0, to: 100)
        let ios = tracker.laneUtilizations[0]
        XCTAssertEqual(ios.lanes, 2, "同じデバイス名の label はポートが違っても1レーン")
        XCTAssertEqual(ios.utilization, 1.0, accuracy: 0.001)
    }

    func testLaneKeyDropsOnlyTheTrailingPlatformGroup() {
        XCTAssertEqual(RunWorker.laneKey(fromLabel: "iPhone 17 Pro(iOS 27.0)-02(ios:8123)"),
                       "iPhone 17 Pro(iOS 27.0)-02")
        XCTAssertEqual(RunWorker.laneKey(fromLabel: "Pixel 9(Android 15)-01(android:emulator-5554)"),
                       "Pixel 9(Android 15)-01")
        XCTAssertEqual(RunWorker.laneKey(fromLabel: "ios:8123"), "ios:8123", "非プロファイル経路は label のまま")
        XCTAssertEqual(RunWorker.laneKey(fromLabel: "android"), "android")
    }

    func testLanesCountOnlyWorkersThatActuallyRan() {
        // 供給されただけで1本も実行しなかったデバイスは分母に入らない
        // (入れると「増やしたのに稼働率が下がった」と誤読させる)
        var tracker = ScenarioTimingTracker()
        run(&tracker, "A", worker: "ios:8123", from: 0, to: 100)
        XCTAssertEqual(tracker.laneUtilizations[0].lanes, 1)
    }

    func testRequeuedScenarioCountsBothWorkersAsLanes() {
        // 振り直しで開始と終了のワーカーが変わる。どちらもレーンとして数える
        // (数え落とすと分母が小さくなり、稼働率が実際より高く見える)。
        // 所要をどちら側の platform に計上するかは、キューが platform 別で
        // 振り直しが platform を跨がないため現状どちらでも同じ値になる。
        var tracker = ScenarioTimingTracker()
        tracker.record(.flowStarted(worker: "android:emulator-5554", flowURL: url("A"),
                                    flowName: "A", isDirty: false), at: at(0))
        tracker.record(.flowFinished(worker: "android:emulator-5556", flowURL: url("A"),
                                     passed: true, triage: nil, reportURL: nil, fm: nil), at: at(30))

        let stats = tracker.laneUtilizations
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].platform, "android")
        XCTAssertEqual(stats[0].busySeconds, 30, accuracy: 0.001)
        XCTAssertEqual(stats[0].lanes, 2, "開始側と終了側の両方をレーンとして数える")
    }

    func testEmptyRunHasNoUtilizations() {
        XCTAssertTrue(ScenarioTimingTracker().laneUtilizations.isEmpty)
    }

    // MARK: - 助言の判定

    private func stat(_ platform: String, lanes: Int, utilization: Double,
                      lastFinish: Double) -> LaneUtilization {
        LaneUtilization(platform: platform, lanes: lanes,
                        busySeconds: utilization * Double(lanes) * lastFinish,
                        lastFinishSeconds: lastFinish, utilization: utilization)
    }

    func testAdvisesRebalanceOnTheMeasuredImbalance() {
        // §3.6 の実測そのもの
        let message = LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.92, lastFinish: 185),
            stat("android", lanes: 5, utilization: 0.36, lastFinish: 88),
        ])
        let text = try? XCTUnwrap(message)
        XCTAssertNotNil(text, "遊休レーンがあるなら振り替えを勧めること")
        XCTAssertTrue(text?.contains("android") == true)
        XCTAssertTrue(text?.contains("ios") == true)
    }

    func testSilentWhenBothPlatformsAreBusy() {
        // 両方詰まっているなら振り替えても縮まない
        XCTAssertNil(LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.92, lastFinish: 185),
            stat("android", lanes: 5, utilization: 0.88, lastFinish: 180),
        ]))
    }

    func testSilentWhenIdlePlatformFinishesNearlyTogether() {
        // 稼働率は低くても、ほぼ同時に終わっているなら振り替えの余地は小さい
        XCTAssertNil(LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.92, lastFinish: 185),
            stat("android", lanes: 5, utilization: 0.40, lastFinish: 180),
        ]))
    }

    func testSilentWhenCriticalPathIsNotBusy() {
        // どちらも遊休(= 律速はレーン数ではない。デバイス供給待ち等)なら配分の話ではない
        XCTAssertNil(LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.30, lastFinish: 185),
            stat("android", lanes: 5, utilization: 0.10, lastFinish: 40),
        ]))
    }

    func testSilentWhenIdlePlatformHasOnlyOneLane() {
        // 1台しかないなら振り替える余地が無い(0台にはできない)
        XCTAssertNil(LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.92, lastFinish: 185),
            stat("android", lanes: 1, utilization: 0.20, lastFinish: 40),
        ]))
    }

    func testSilentForSinglePlatformRun() {
        XCTAssertNil(LaneBalanceAdvice.message(for: [
            stat("ios", lanes: 5, utilization: 0.92, lastFinish: 185),
        ]))
    }
}
