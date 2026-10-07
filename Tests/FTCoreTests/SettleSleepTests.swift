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
            let sleep = StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: true, treeLags: false)
            XCTAssertEqual(sleep + cost, interval,
                           "迂回時は sleep + snapshot が周期(\(interval)ms)に一致すること")
        }
    }

    func testNonBypassingEngineKeepsTheFullInterval() {
        // iOS xcuitest の snapshot は数百 ms 掛かる。ここで引くと周期が縮んで誤判定に倒れる
        for cost in [5, 380, 900] {
            XCTAssertEqual(StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: false, treeLags: false),
                           StepExecutor.scrollSettleIntervalMs,
                           "迂回しないエンジンでは待ちを縮めないこと")
        }
    }

    func testSleepNeverFallsBelowTheFloor() {
        // snapshot が周期より重いときに busy loop へ落ちないこと
        for cost in [StepExecutor.scrollSettleIntervalMs, 500, 10_000] {
            XCTAssertEqual(StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: true, treeLags: false),
                           StepExecutor.scrollSettleMinSleepMs)
        }
    }

    func testFloorIsBelowTheInterval() {
        XCTAssertLessThan(StepExecutor.scrollSettleMinSleepMs, StepExecutor.scrollSettleIntervalMs,
                          "下限が周期以上だと差し引きが常に無効になる")
    }

    /// 木が動きに遅れるエンジン(XCUITest)は、待ち + 取得の周期が 350ms を下回らない(定数の doc の実測)
    func testLaggingTreeKeepsThePeriodAtLeast350ms() {
        XCTAssertEqual(StepExecutor.laggingTreeSettlePeriodMs, 350)
        for cost in [5, 20, 100] {
            let sleep = StepExecutor.settleSleepMs(afterSnapshotMs: cost, bypassing: false, treeLags: true)
            XCTAssertGreaterThanOrEqual(sleep + cost, 350, "cost=\(cost)")
        }
        XCTAssertEqual(StepExecutor.settleSleepMs(afterSnapshotMs: 900, bypassing: false, treeLags: true),
                       StepExecutor.scrollSettleIntervalMs, "取得が周期より重いときは従来の待ち")
    }

    /// **配線**: 整定(settledSignature)が driver.treeLagsBehindMotion を見て周期を延ばす。所要で測る
    func testSettledSignatureWaitsLongerWhenTheTreeLags() async throws {
        func elapsedMs(lags: Bool) async throws -> Double {
            let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: [[]])
            driver.treeLags = lags
            let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            var phase = StepExecutor.PhaseAccumulator()
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await executor.settledSignature(phase: &phase)
            let d = clock.now - start
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let lagging = try await elapsedMs(lags: true)
        XCTAssertGreaterThanOrEqual(lagging, 340, "XCUITest では 2 枚の間隔が 350ms 以上")
        let normal = try await elapsedMs(lags: false)
        XCTAssertLessThan(normal, 340, "遅れないエンジンは従来の 100ms 周期のまま")
    }
}
