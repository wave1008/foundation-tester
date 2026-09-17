// M18: guest reboot 前後の再判定(excludeOrRepairBlankScreenWorkers)の純粋部分。
// 実測: E2E-Flutter/android のラウンド開始時、毎回ちょうど1台が「flap 検知(2サンプル×1.5秒)」
// だけで持続と誤判定され、破壊的な guest reboot(1〜2分)まで走っていた。
// - reboot 直前の再判定(既定の5サンプル×8秒窓)で自然に晴れたかを見る側は、実機・adb が要るため
//   ここではその判定に使う純粋関数(evidence 文・ポーリング継続の可否)だけを検証する。

import XCTest
@testable import FTAndroid

final class ProfileWorkerFactoryBlankRebootTests: XCTestCase {

    // MARK: - uniformBlankEvidenceText(純粋関数)

    func testUniformBlankEvidenceTextMatchesTheFlapCheckParameters() {
        let text = ProfileWorkerFactory.uniformBlankEvidenceText(samples: 2, intervalMs: 1_500)
        XCTAssertEqual(text, "the screen was a single uniform color in 2 captures 1.5s apart")
    }

    func testUniformBlankEvidenceTextFormatsWholeSecondsWithoutADecimal() {
        let text = ProfileWorkerFactory.uniformBlankEvidenceText(samples: 5, intervalMs: 8_000)
        XCTAssertEqual(text, "the screen was a single uniform color in 5 captures 8s apart")
    }

    // MARK: - blankPollShouldContinue(純粋関数)

    func testPollContinuesWhileWithinBudget() {
        XCTAssertTrue(ProfileWorkerFactory.blankPollShouldContinue(
            elapsedSeconds: 10, budgetSeconds: 120))
    }

    func testPollStopsOnceBudgetIsExhausted() {
        XCTAssertFalse(ProfileWorkerFactory.blankPollShouldContinue(
            elapsedSeconds: 120, budgetSeconds: 120))
        XCTAssertFalse(ProfileWorkerFactory.blankPollShouldContinue(
            elapsedSeconds: 121, budgetSeconds: 120))
    }
}
