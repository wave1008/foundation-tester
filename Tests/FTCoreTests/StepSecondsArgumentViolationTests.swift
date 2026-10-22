// FlowStep.secondsArgumentViolation と StepExecutor.executeStep の入口の検査。
// 範囲外(非有限・負・1e15 超)の waitSeconds / intervalSeconds は下流の `.seconds(Double)` / `Int(秒 * 1000)` で trap する
// (テストプロセスごと落ちる)ので、検査を外す変異はこのテストの中断として現れる。

import XCTest
@testable import FTCore

final class StepSecondsArgumentViolationTests: XCTestCase {

    private func message(_ status: StepResult.Status) -> String? {
        if case .failed(let text) = status { return text }
        return nil
    }

    func testFiniteNonNegativeSecondsAreAccepted() {
        for seconds in [0.0, 0.5, 120.0, 1e15] {
            XCTAssertNil(FlowStep(action: "tap", timeout: seconds).secondsArgumentViolation, "\(seconds)")
            XCTAssertNil(FlowStep(action: "flick", intervalSeconds: seconds).secondsArgumentViolation, "\(seconds)")
        }
        XCTAssertNil(FlowStep(action: "tap").secondsArgumentViolation, "省略(nil)は検査しない")
    }

    func testNonFiniteOrNegativeSecondsAreRejectedByName() {
        // 1e30 は有限でも `.seconds(1e30)` が Int128 の乗算で trap する(上限は ArgumentBounds.waitSecondsCeiling = 1e15)
        for seconds in [Double.infinity, -.infinity, .nan, -1, 1.1e15, 1e30] {
            let wait = FlowStep(action: "tap", timeout: seconds).secondsArgumentViolation
            XCTAssertTrue(wait?.hasPrefix("waitSeconds must be a finite, non-negative") == true, "\(seconds): \(wait ?? "nil")")
            let interval = FlowStep(action: "flick", intervalSeconds: seconds).secondsArgumentViolation
            XCTAssertTrue(interval?.hasPrefix("intervalSeconds must be a finite, non-negative") == true,
                          "\(seconds): \(interval ?? "nil")")
        }
    }

    /// アクションも検証も、ドライバへ触る前に断る(検証は executeAction を通らないので入口の検査だけが守る)
    func testExecutorRejectsBeforeAnyDriverCall() async {
        let steps = [
            FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: .infinity),
            FlowStep(assert: "exists", locator: FlowLocator(id: "missing"), timeout: .nan),
            FlowStep(action: "flick", direction: "up", intervalSeconds: .infinity),
            FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 1e30),
        ]
        for step in steps {
            let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
            let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)
            XCTAssertTrue((message(outcome.status) ?? "").contains("must be a finite, non-negative"),
                          "\(step): \(outcome.status)")
            XCTAssertEqual(driver.log.entries, [], "\(step): 弾いたステップはドライバへ触れない")
            XCTAssertEqual(driver.snapshotCallCount, 0, "\(step)")
        }
    }
}
