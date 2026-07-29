// LPT(Longest Processing Time first)投入順の決定ロジック。
// 並列ワーカーは空き次第キューの先頭から取るため、投入順がそのまま壁時計に効く。
// 順序が壊れても全シナリオは実行され成功するので、E2E では捕まらない。

import XCTest
@testable import FTCore

final class LPTSchedulerTests: XCTestCase {

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp",
                                           platform: nil, deleted: false))
    }

    private func ids(_ items: [ScenarioRunItem]) -> [String] { items.map(\.info.id) }

    private func duration(_ id: String, _ ms: Double,
                          _ platform: String = "android") -> LPTScheduler.Duration {
        LPTScheduler.Duration(scenarioID: id, platform: platform, medianMs: ms)
    }

    /// item は platform 未指定なので defaultPlatform("android")で解決される
    private func order(_ items: [ScenarioRunItem],
                       _ durations: [LPTScheduler.Duration]) -> [ScenarioRunItem] {
        LPTScheduler.order(items, durations: durations, defaultPlatform: "android")
    }

    // MARK: - 並べ替え

    func testOrdersByDescendingMedianDuration() {
        let result = order([item("短"), item("長"), item("中")], [duration("短", 1_000), duration("長", 30_000), duration("中", 5_000)])
        XCTAssertEqual(ids(result), ["長", "中", "短"])
    }

    func testUnknownScenariosGoFirst() {
        // 実績が無いものを末尾に回すと、それが長かったときに LPT の狙いが裏返る。悲観側へ倒す
        let result = order([item("既知短"), item("新規"), item("既知長")], [duration("既知短", 1_000), duration("既知長", 30_000)])
        XCTAssertEqual(ids(result), ["新規", "既知長", "既知短"])
    }

    func testStableForEqualDurations() {
        // 実行順が run ごとに揺れると前後比較ができない。同値は元の順序を保つ。
        // Swift の sort は安定性を保証しないため、要素数を増やさないと偶然順序が保たれて
        // 不安定な実装を見逃す(3要素では検出できなかった)
        let items = (1...30).map { item("S\($0)") }
        let result = order(items, items.map { duration($0.info.id, 5_000) })
        XCTAssertEqual(ids(result), ids(items))
    }

    func testStableAmongUnknowns() {
        let items = (1...30).map { item("S\($0)") }
        let result = order(items, [])
        XCTAssertEqual(ids(result), ids(items), "全て実績なしなら元の順序のまま")
    }

    func testEmptyInput() {
        XCTAssertTrue(order([], [duration("A", 1)]).isEmpty)
    }

    func testIgnoresDurationsForScenariosNotInThisRun() {
        // 過去に走ったが今回選ばれていないシナリオの実績が混ざっても順序に影響しない
        let result = order([item("A"), item("B")], [duration("A", 1_000), duration("B", 2_000), duration("昔のシナリオ", 99_000)])
        XCTAssertEqual(ids(result), ["B", "A"])
    }

    func testPreservesAllItems() {
        // 並べ替えで取りこぼしたら実行されないシナリオが出る
        let items = (1...20).map { item("S\($0)") }
        let result = order(items, [duration("S7", 100)])
        XCTAssertEqual(result.count, items.count)
        XCTAssertEqual(Set(ids(result)), Set(ids(items)))
    }

    func testDuplicateDurationEntriesUseTheFirst() {
        // 同一 scenarioID が2件来ても落ちない(集計元が壊れていても実行は止めない)
        let result = order([item("A"), item("B")], [duration("A", 100), duration("A", 90_000), duration("B", 1_000)])
        XCTAssertEqual(ids(result), ["B", "A"], "先勝ちで 100ms 扱い")
    }

    // MARK: - platform 別の実績

    private func iosItem(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp",
                                           platform: "ios", deleted: false))
    }

    func testUsesTheDurationOfThePlatformTheScenarioRunsOn() {
        // 同じシナリオが iOS では遅く Android では速い。混ぜると中間値になって順序が歪む
        let durations = [duration("両対応", 30_000, "ios"), duration("両対応", 2_000, "android"),
                         duration("Android専用", 5_000, "android")]
        // defaultPlatform=android なので platform 未指定の「両対応」は android の 2,000ms 扱い
        let result = order([item("両対応"), item("Android専用")], durations)
        XCTAssertEqual(ids(result), ["Android専用", "両対応"])
    }

    func testExplicitPlatformSelectsThatPlatformsHistory() {
        let durations = [duration("両対応", 30_000, "ios"), duration("両対応", 2_000, "android"),
                         duration("Android専用", 5_000, "android")]
        // platform: "ios" を明示したシナリオは ios の 30,000ms で評価される
        let result = LPTScheduler.order([iosItem("両対応"), item("Android専用")],
                                        durations: durations, defaultPlatform: "android")
        XCTAssertEqual(ids(result), ["両対応", "Android専用"])
    }

    func testMissingPlatformHistoryIsTreatedAsUnknown() {
        // ios の実績しか無いシナリオを android の run で並べる場合は「実績なし」= 先頭
        let result = order([item("A"), item("B")],
                           [duration("A", 30_000, "ios"), duration("B", 1_000, "android")])
        XCTAssertEqual(ids(result), ["A", "B"], "A は android の実績が無いので先頭")
    }
}

/// LPT は「items 全体を並べれば platform 別キューも LPT 順になる」ことに依存している。
/// RunOrchestrator.run は Dictionary(grouping:) で platform ごとに分けるため、
/// **グループ内の相対順序が保たれること**が前提。仮定のままにせずここで固定する。
final class PlatformGroupingOrderTests: XCTestCase {

    func testGroupingPreservesRelativeOrderWithinEachPlatform() {
        let items: [(id: String, platform: String)] = [
            ("ios長", "ios"), ("and長", "android"), ("ios中", "ios"),
            ("and短", "android"), ("ios短", "ios"),
        ]
        let grouped = Dictionary(grouping: items) { $0.platform }
        XCTAssertEqual(grouped["ios"]?.map(\.id), ["ios長", "ios中", "ios短"])
        XCTAssertEqual(grouped["android"]?.map(\.id), ["and長", "and短"])
    }
}
