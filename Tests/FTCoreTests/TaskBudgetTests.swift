// TaskBudget が守るのは2つ: **予算内なら結果をそのまま返す**ことと、
// **諦めた後も仕事を止めない**こと(止めると初期化がやり直しになる。TaskBudget の冒頭)。

import Foundation
import XCTest
@testable import FTCore

final class TaskBudgetTests: XCTestCase {

    func testReturnsTheValueWhenItFitsInTheBudget() async {
        let outcome = await TaskBudget.run(.seconds(10)) { 42 }
        guard case .value(let v) = outcome else { return XCTFail("予算内なのに諦めた") }
        XCTAssertEqual(v, 42)
    }

    /// **測るのは戻り値ではなく所要**(2026-09-10 に実際に間違えた): `.exhausted` を返しながら
    /// 仕事の完了まで待っていると、諦めた意味が無いのにテストは緑になる
    func testExhaustsAtTheBudgetWithoutWaitingForTheWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await TaskBudget.run(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        let elapsed = clock.now - start
        guard case .exhausted = outcome else { return XCTFail("予算を超えたのに待ち切った") }
        XCTAssertLessThan(elapsed, .seconds(2),
                          "予算で諦めたのに仕事の完了まで待っている(所要 \(elapsed))")
    }

    /// **諦めた後も仕事は走り続ける** —— ここが逆になると、次の呼び出しもまた予算を使い切る
    /// (Vision のモデルロードはプロセスに1回。TaskBudget の冒頭)
    func testAbandonedWorkIsNotCancelled() async {
        let finished = Finished()
        let outcome = await TaskBudget.run(.milliseconds(50)) {
            try? await Task.sleep(for: .milliseconds(400))
            // 巻き添えで cancel されていれば Task.sleep が throw して**ここへ来ない**
            finished.mark(cancelled: Task.isCancelled)
            return 1
        }
        guard case .exhausted = outcome else { return XCTFail("予算を超えたのに待ち切った") }
        try? await Task.sleep(for: .seconds(1))
        XCTAssertTrue(finished.completed, "諦めた仕事が巻き添えで止まっている")
        XCTAssertFalse(finished.wasCancelled, "諦めた仕事に cancel が伝播している")
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cancelled = false
        func mark(cancelled value: Bool) {
            lock.lock(); done = true; cancelled = value; lock.unlock()
        }
        var completed: Bool { lock.lock(); defer { lock.unlock() }; return done }
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
}

/// 合流点(Gate)の契約: **先に届いたほうだけを採る**。
/// 後着が勝つと、仕事が終わっているのに `.exhausted` を返す(結果を捨てる)ことが起こりうる。
final class TaskBudgetGateTests: XCTestCase {

    /// 待ち始める前に 2 本届いても**先着**が返る
    func testFirstDeliveryWinsEvenBeforeAnyoneWaits() async {
        let gate = TaskBudget.Gate<Int>()
        gate.deliver(.value(1))
        gate.deliver(.exhausted)
        guard case .value(let v) = await gate.wait() else {
            return XCTFail("後から届いた予算切れが先着の結果を上書きした")
        }
        XCTAssertEqual(v, 1)
    }

    /// 待っている最中に 2 本届いても落ちない(継続の二重 resume はクラッシュ)
    func testSecondDeliveryWhileWaitingIsDropped() async {
        let gate = TaskBudget.Gate<Int>()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            gate.deliver(.value(7))
            gate.deliver(.exhausted)
        }
        guard case .value(let v) = await gate.wait() else { return XCTFail("先着が採られていない") }
        XCTAssertEqual(v, 7)
    }
}

/// 諦めた仕事の**本当の所要**を残す口(`onLateFinish`)。両方向で固定する ——
/// 予算内に終わった回に呼ぶと「遅かった」の記録が嘘になる
final class TaskBudgetLateFinishTests: XCTestCase {

    func testLateFinishFiresOnlyAfterExhaustionWithTheRealElapsed() async {
        let seen = LateSeen()
        let outcome = await TaskBudget.run(.milliseconds(50), onLateFinish: { v, elapsed in
            seen.record(v, elapsed)
        }) {
            try? await Task.sleep(for: .milliseconds(300))
            return 9
        }
        guard case .exhausted = outcome else { return XCTFail("予算を超えたのに待ち切った") }
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(seen.value, 9, "遅れて終わった仕事の値が届いていない")
        XCTAssertGreaterThanOrEqual(seen.elapsed ?? .zero, .milliseconds(250),
                                    "所要が仕事の全長ではない(予算で切った値になっている)")
    }

    func testLateFinishDoesNotFireWhenTheWorkFitsInTheBudget() async {
        let seen = LateSeen()
        let outcome = await TaskBudget.run(.seconds(5), onLateFinish: { v, e in seen.record(v, e) }) { 1 }
        guard case .value = outcome else { return XCTFail("予算内なのに諦めた") }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(seen.value, "予算内に終わった回を「遅かった」と記録している")
    }

    private final class LateSeen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value: Int?
        private(set) var elapsed: Duration?
        func record(_ v: Int, _ e: Duration) { lock.lock(); value = v; elapsed = e; lock.unlock() }
    }
}
