// `ScenarioIdleWatch`(純粋な値型)と `ScenarioIdleBudget` の固定。ScenarioHost の idle 打ち切りが使う判定。

import XCTest
@testable import FTCore

final class ScenarioIdleWatchTests: XCTestCase {

    private let t0 = SuspendingClock().now

    private func watch() -> ScenarioIdleWatch {
        var w = ScenarioIdleWatch(budget: .seconds(10))
        w.start(at: t0)
        return w
    }

    func testBudgetIsTwiceCommandTimeoutPinned() {
        XCTAssertEqual(ScenarioIdleBudget.seconds(commandTimeout: 120), 240)
        XCTAssertEqual(ScenarioIdleBudget.seconds(commandTimeout: 0.25), 0.5)
    }

    func testSilenceUpToBudgetIsAllowed() {
        let w = watch()
        XCTAssertNil(w.overBudget(at: t0 + .seconds(10)))
        XCTAssertEqual(w.deadline, t0 + .seconds(10))
    }

    func testSilenceOverBudgetIsReported() {
        let w = watch()
        XCTAssertEqual(w.overBudget(at: t0 + .milliseconds(10_001)),
                       IdleGap(silentFor: .milliseconds(10_001), allowed: .seconds(10)))
    }

    func testActivityMovesTheDeadline() {
        var w = watch()
        w.activity(at: t0 + .seconds(8))
        XCTAssertNil(w.overBudget(at: t0 + .seconds(17)))
        XCTAssertEqual(w.deadline, t0 + .seconds(18))
        XCTAssertEqual(w.silence(at: t0 + .seconds(17)), .seconds(9))
    }

    func testOlderActivityDoesNotRewindTheLastOutput() {
        var w = watch()
        w.activity(at: t0 + .seconds(8))
        w.activity(at: t0 + .seconds(3))  // 別のパイプの遅れて届いた記録
        XCTAssertEqual(w.deadline, t0 + .seconds(18))
    }

    func testOpenExclusionWindowExtendsTheAllowance() {
        var w = watch()
        w.activity(at: t0 + .seconds(1))
        w.setOpenExclusionCap(.seconds(100))
        XCTAssertNil(w.overBudget(at: t0 + .seconds(1 + 110)))
        XCTAssertEqual(w.overBudget(at: t0 + .seconds(1 + 111)),
                       IdleGap(silentFor: .seconds(111), allowed: .seconds(110)))
    }

    func testClosedWindowStopsExtending() {
        var w = watch()
        w.setOpenExclusionCap(.seconds(100))
        w.activity(at: t0 + .seconds(2))
        w.setOpenExclusionCap(.zero)
        XCTAssertNotNil(w.overBudget(at: t0 + .seconds(2 + 11)))
    }

    func testDeclaredWaitExtendsTheAllowanceUntilItEnds() {
        var w = watch()
        w.beginAllowance(.seconds(300))
        XCTAssertNil(w.overBudget(at: t0 + .seconds(310)))
        w.endAllowance()
        XCTAssertNotNil(w.overBudget(at: t0 + .seconds(11)))
    }

    func testNestedDeclaredWaitsUseTheLargest() {
        var w = watch()
        w.beginAllowance(.seconds(300))
        w.beginAllowance(.seconds(5))
        XCTAssertEqual(w.allowed, .seconds(310))
        w.endAllowance()
        XCTAssertEqual(w.allowed, .seconds(310))
        w.endAllowance()
        w.endAllowance()  // 対の無い ended は無視
        XCTAssertEqual(w.allowed, .seconds(10))
    }
}
