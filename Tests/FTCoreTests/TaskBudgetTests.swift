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

    func testExhaustsWhenTheWorkIsSlowerThanTheBudget() async {
        let outcome = await TaskBudget.run(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        guard case .exhausted = outcome else { return XCTFail("予算を超えたのに待ち切った") }
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
