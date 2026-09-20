// RunProgressEstimate(残り見積もり。docs/design.md §18.4)の検証。式は仕様のまま:
//   残り = Σ(未着手の推定) + Σ(実行中レーンの max(0, 推定 - 経過))
//   eta  = max( 残っている単一ジョブの最大, 残り ÷ 生きているレーン数 )
// 守るもの: ①実績ゼロは nil ②1レーンは総和がそのまま出る ③複数レーンは「総和÷レーン数」と
// 「最長ジョブ」のどちらが勝つかで正しく分岐する ④実行中の経過が推定を超えても残りは負にならない
// ⑤一部だけ実績が無いときは中央値の中央値で埋める ⑥丸めは切り上げ(下界を下回って見せない)。

import XCTest
@testable import FTCore

final class RunProgressEstimateTests: XCTestCase {

    private func key(_ id: String, _ platform: String = "ios") -> RunProgressEstimate.ScenarioKey {
        RunProgressEstimate.ScenarioKey(scenarioID: id, platform: platform)
    }

    // MARK: - etaSeconds

    func testEmptyTableReturnsNilRegardlessOfPendingOrRunning() {
        let eta = RunProgressEstimate.etaSeconds(
            table: [:], pending: [key("A")], running: [(scenario: key("B"), elapsedSeconds: 0)],
            liveLanes: 3)
        XCTAssertNil(eta, "実績が1件も無い run は推測値を出さない")
    }

    func testZeroLiveLanesReturnsNil() {
        let eta = RunProgressEstimate.etaSeconds(
            table: [key("A"): 5_000], pending: [key("A")], running: [], liveLanes: 0)
        XCTAssertNil(eta, "0除算を避け、生きているレーンが無ければ計算しない")
    }

    /// 1レーン: 生きているレーンが1本なら「残り÷レーン数」は「残りの総和」そのもの。
    /// 最長ジョブ(7秒)より総和(12秒)のほうが大きいので、総和が勝つことを確かめる
    func testSingleLaneUsesTheSumOfRemainingWork() {
        let table = [key("A"): 5_000.0, key("B"): 7_000.0]
        let eta = RunProgressEstimate.etaSeconds(
            table: table, pending: [key("A"), key("B")], running: [], liveLanes: 1)
        XCTAssertEqual(eta, 12, "5秒+7秒 = 12秒(1レーンなので÷1)")
    }

    /// 複数レーン・「総和÷レーン数」が勝つ場合: 4本×10秒・2レーン → 総和40秒÷2=20秒、
    /// 最長ジョブは10秒なので 20 が勝つ
    func testMultipleLanesSumOverLanesWinsWhenBalanced() {
        let table = [key("A"): 10_000.0]
        let pending = [key("A"), key("A"), key("A"), key("A")]
        let eta = RunProgressEstimate.etaSeconds(table: table, pending: pending, running: [], liveLanes: 2)
        XCTAssertEqual(eta, 20, "40秒 ÷ 2レーン = 20秒 > 最長ジョブ10秒")
    }

    /// 複数レーン・「最長ジョブ」が勝つ場合: 100秒のジョブ1本 + 1秒のジョブ1本・2レーン →
    /// 総和101秒÷2=50.5秒だが、100秒のジョブ1本は2レーンに分けられないので eta は100秒を下回れない
    func testMultipleLanesLongestSingleJobWinsWhenUnbalanced() {
        let table = [key("Long"): 100_000.0, key("Short"): 1_000.0]
        let eta = RunProgressEstimate.etaSeconds(
            table: table, pending: [key("Long"), key("Short")], running: [], liveLanes: 2)
        XCTAssertEqual(eta, 100, "101秒 ÷ 2 = 50.5秒 < 最長ジョブ100秒なので100秒が勝つ")
    }

    /// 丸めは切り上げ: 3本×7秒・2レーン → 21秒÷2=10.5秒 → 11秒(下界を下回って見せない)
    func testRemainingIsRoundedUp() {
        let table = [key("A"): 7_000.0]
        let pending = [key("A"), key("A"), key("A")]
        let eta = RunProgressEstimate.etaSeconds(table: table, pending: pending, running: [], liveLanes: 2)
        XCTAssertEqual(eta, 11, "10.5秒は切り上げて11秒(切り捨てると実際より早く終わって見える)")
    }

    /// 実行中レーンの経過が推定を超えていても、その分の残りは 0 に留まり負にならない
    func testRunningElapsedPastTheEstimateClampsToZero() {
        let table = [key("A"): 1_000.0]  // 1秒
        let eta = RunProgressEstimate.etaSeconds(
            table: table, pending: [], running: [(scenario: key("A"), elapsedSeconds: 999)],
            liveLanes: 1)
        XCTAssertEqual(eta, 0, "1秒の見積もりに999秒経過していても残りは0(負にはならない)")
    }

    /// 実行中レーンの残り(max(0, 推定-経過))と未着手の推定を合算する。2レーンとも実行中で
    /// 未着手なし: A は推定10秒・経過4秒 → 残り6秒/ B は推定10秒・経過9秒 → 残り1秒。
    /// 総和7秒÷2レーン=3.5秒 < 最長の残り6秒なので6秒が勝つ
    func testRunningLanesContributeTheirOwnRemainingTime() {
        let table = [key("A"): 10_000.0, key("B"): 10_000.0]
        let running: [(scenario: RunProgressEstimate.ScenarioKey, elapsedSeconds: Double)] =
            [(key("A"), 4), (key("B"), 9)]
        let eta = RunProgressEstimate.etaSeconds(table: table, pending: [], running: running, liveLanes: 2)
        XCTAssertEqual(eta, 6, "残り6秒(A) と 1秒(B) の和7秒÷2=3.5秒より最長の残り6秒が勝つ")
    }

    // MARK: - estimateTable

    func testEstimateTableIsEmptyWhenThereAreNoDurations() {
        let table = RunProgressEstimate.estimateTable(durations: [], scenarios: [key("A")])
        XCTAssertTrue(table.isEmpty, "実績が1件も無ければ空のまま(呼び手はこれで「計算不能」と判定する)")
    }

    /// 一部のシナリオにだけ実績が無いときは、実績のある中央値の中央値で埋める
    /// (FleetRunner.runSplit の unknownDurationMs と同じ考え方)
    func testEstimateTableFillsUnknownScenariosWithTheMedianOfKnownMedians() {
        let durations = [
            LPTScheduler.Duration(scenarioID: "A", platform: "ios", medianMs: 10_000),
            LPTScheduler.Duration(scenarioID: "B", platform: "ios", medianMs: 20_000),
        ]
        let table = RunProgressEstimate.estimateTable(
            durations: durations, scenarios: [key("A"), key("B"), key("C")])
        XCTAssertEqual(table[key("A")], 10_000, "実績のあるシナリオはそのまま")
        XCTAssertEqual(table[key("B")], 20_000, "実績のあるシナリオはそのまま")
        XCTAssertEqual(table[key("C")], 15_000, "実績が無いシナリオは中央値(10000,20000)の中央値=15000で埋める")
    }

    /// scenarios に無いシナリオ(runnableScenarios に含まれない鍵)を穴埋め対象にしない
    /// (呼び手が渡した「この run に出てくる」集合だけを埋める)
    func testEstimateTableDoesNotAddEntriesOutsideTheGivenScenarios() {
        let durations = [LPTScheduler.Duration(scenarioID: "A", platform: "ios", medianMs: 10_000)]
        let table = RunProgressEstimate.estimateTable(durations: durations, scenarios: [key("A")])
        XCTAssertEqual(table.count, 1)
        XCTAssertNil(table[key("Z")])
    }
}
