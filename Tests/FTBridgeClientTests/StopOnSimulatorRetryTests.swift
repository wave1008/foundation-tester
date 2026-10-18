// simctl terminate が時間切れ(完了したか分からない)の回だけ 1 回撃ち直すこと。止める操作は何度撃っても結果が同じ
// (止まっていれば 3)なので、撃ち直しで二重実行の害は無い。それ以外の失敗は撃ち直さずに投げる

import XCTest
import FTCore
@testable import FTBridgeClient

final class StopOnSimulatorRetryTests: XCTestCase {

    private func run(_ results: [Result<(status: Int32, tail: String), Error>]) -> (error: Error?, calls: Int) {
        var queue = results
        var calls = 0
        do {
            try BridgeClient.stopOnSimulator(bundleID: "com.x", purpose: "before clearing its data") {
                calls += 1
                return try queue.removeFirst().get()
            }
            return (nil, calls)
        } catch {
            return (error, calls)
        }
    }

    func testABrokeredTimeoutIsRetriedOnceAndTheRetrySucceeds() {
        let outcome = run([.success((SandboxBroker.didNotCompleteStatus, "did not complete")), .success((0, ""))])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.calls, 2)
    }

    func testAThrownTimeoutIsRetriedAndAlreadyStoppedCounts() {
        let outcome = run([.failure(ShellError.timedOut(args: ["xcrun"], seconds: 15)), .success((3, ""))])
        XCTAssertNil(outcome.error, "3 = 動いていなかった = 止まっている")
        XCTAssertEqual(outcome.calls, 2)
    }

    func testTwoTimeoutsFailWithoutAThirdAttempt() {
        let outcome = run([.success((SandboxBroker.didNotCompleteStatus, "")),
                           .failure(ShellError.timedOut(args: ["xcrun"], seconds: 15))])
        XCTAssertEqual(outcome.calls, 2)
        let message = String(describing: outcome.error ?? NSError(domain: "none", code: 0))
        XCTAssertTrue(message.contains("did not complete within 15s, twice"), message)
    }

    func testAnOrdinaryFailureIsNotRetried() {
        let outcome = run([.success((1, "Invalid device")), .success((0, ""))])
        XCTAssertEqual(outcome.calls, 1)
        XCTAssertNotNil(outcome.error)
    }

    /// 既定値をリテラルで固定する(子の代行の「完了しなかった」= 127・terminate 1 回の上限 15 秒)
    func testConstantsArePinned() {
        XCTAssertEqual(SandboxBroker.didNotCompleteStatus, 127)
        XCTAssertEqual(BridgeClient.stopOnSimulatorTimeoutSeconds, 15)
    }
}
