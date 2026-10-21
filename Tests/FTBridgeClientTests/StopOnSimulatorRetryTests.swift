// simctl terminate が時間切れ(完了したか分からない)の回だけ 1 回撃ち直し、「Host is down」(64)は窓の間だけ撃ち直すこと。
// 止める操作は何度撃っても結果が同じ(止まっていれば 3)なので、撃ち直しで二重実行の害は無い。それ以外の失敗は撃ち直さずに投げる

import XCTest
import FTCore
@testable import FTBridgeClient

final class StopOnSimulatorRetryTests: XCTestCase {

    /// 待ちは撃たない(pause を空にする)。`window` は「Host is down」の撃ち直しの窓
    private func run(_ results: [Result<(status: Int32, tail: String), Error>],
                     window: Duration = .seconds(60)) -> (error: Error?, calls: Int, logs: [String]) {
        var queue = results
        var calls = 0
        var logs: [String] = []
        do {
            try BridgeClient.stopOnSimulator(bundleID: "com.x", purpose: "before clearing its data",
                                             hostDownWindow: window, pause: { _ in }, log: { logs.append($0) }) {
                calls += 1
                return try queue.removeFirst().get()
            }
            return (nil, calls, logs)
        } catch {
            return (error, calls, logs)
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

    /// SpringBoard が一時的に答えない(64)回は撃ち直し、通ったら実行ログへ 1 行残す(黙って消さない)
    func testHostDownIsRetriedUntilTheSimulatorAnswers() {
        let hostDown: Result<(status: Int32, tail: String), Error> = .success((64, "Host is down"))
        let outcome = run([hostDown, hostDown, .success((0, ""))])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.calls, 3)
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertTrue(outcome.logs.first?.contains("after 2 retries") == true, outcome.logs.description)
    }

    /// 撃ち直しの途中で「動いていなかった」(3)が返っても止まっている扱い
    func testHostDownThenAlreadyStoppedCounts() {
        let outcome = run([.success((64, "Host is down")), .success((3, ""))])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.calls, 2)
    }

    /// 窓が尽きたら撃ち直した旨を添えて投げる(無限に撃たない)
    func testHostDownThatNeverClearsFailsAfterTheWindow() {
        var calls = 0
        var logs: [String] = []
        var error: Error?
        do {
            try BridgeClient.stopOnSimulator(bundleID: "com.x", purpose: "before clearing its data",
                                             hostDownWindow: .milliseconds(30), pause: { _ in Thread.sleep(forTimeInterval: 0.005) },
                                             log: { logs.append($0) }) {
                calls += 1
                return (64, "Host is down")
            }
        } catch let thrown { error = thrown }
        XCTAssertNotNil(error)
        XCTAssertGreaterThan(calls, 1, "窓の間は撃ち直す")
        XCTAssertLessThan(calls, 50, "窓が尽きたら止める")
        let message = String(describing: error ?? NSError(domain: "none", code: 0))
        XCTAssertTrue(message.contains("host is down") && message.contains("retries over 0.03s"), message)
        XCTAssertTrue(logs.isEmpty, "通らなかった回は成功の記録を出さない")
    }

    /// 撃ち直さずに通った回は何も記録しない
    func testAPlainSuccessLogsNothing() {
        let outcome = run([.success((0, ""))])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.calls, 1)
        XCTAssertTrue(outcome.logs.isEmpty)
    }

    /// 既定値をリテラルで固定する(子の代行の「完了しなかった」= 127・terminate 1 回の上限 15 秒)
    func testConstantsArePinned() {
        XCTAssertEqual(SandboxBroker.didNotCompleteStatus, 127)
        XCTAssertEqual(BridgeClient.stopOnSimulatorTimeoutSeconds, 15)
        XCTAssertEqual(BridgeClient.hostDownStatus, 64)
        XCTAssertEqual(BridgeClient.hostDownRetryWindowSeconds, 15)
        XCTAssertEqual(BridgeClient.hostDownRetryPauseSeconds, 1)
    }
}
