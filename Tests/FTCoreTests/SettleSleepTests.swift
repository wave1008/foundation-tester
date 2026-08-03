// 整定ポーリングの**周期**が一定に保たれることを守る。
//
// 判定したいのは「約 scrollSettleIntervalMs の周期で画面が変わらないこと」であって
// sleep の長さではない。キャッシュ迂回の snapshot は Android で約 +35ms 掛かるので、
// 差し引かないと周期が伸びてスクロール系のステップが丸ごと遅くなる
// (2026-08-03 実測: scroll 系ステップ合計 +3.2s → 差し引きで -2.0s 回収)。
// **迂回しないエンジン(iOS)では引かない** —— あちらは snapshot 自体が重く、
// 引くと周期が大きく縮んで「早すぎる静止判定」に倒れる。

import XCTest
@testable import FTCore

final class SettleSleepTests: XCTestCase {

    func testBypassingSubtractsTheSnapshotCostSoThePeriodStaysConstant() {
        let interval = StepExecutor.scrollSettleIntervalMs
        // Android 実測レンジ(迂回 snapshot ≈ 35〜40ms)
        for cost in [35, 40] {
            let sleep = StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: true)
            XCTAssertEqual(sleep + cost, interval,
                           "迂回時は sleep + snapshot が周期(\(interval)ms)に一致すること")
        }
    }

    func testNonBypassingEngineKeepsTheFullInterval() {
        // iOS xcuitest の snapshot は数百 ms 掛かる。ここで引くと周期が縮んで誤判定に倒れる
        for cost in [5, 380, 900] {
            XCTAssertEqual(StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: false),
                           StepExecutor.scrollSettleIntervalMs,
                           "迂回しないエンジンでは待ちを縮めないこと")
        }
    }

    func testSleepNeverFallsBelowTheFloor() {
        // snapshot が周期より重いときに busy loop へ落ちないこと
        for cost in [StepExecutor.scrollSettleIntervalMs, 500, 10_000] {
            XCTAssertEqual(StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: true),
                           StepExecutor.scrollSettleMinSleepMs)
        }
    }

    func testFloorIsBelowTheInterval() {
        XCTAssertLessThan(StepExecutor.scrollSettleMinSleepMs, StepExecutor.scrollSettleIntervalMs,
                          "下限が周期以上だと差し引きが常に無効になる")
    }
}
