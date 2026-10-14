import XCTest
@testable import FTServices

final class ReadinessScheduleTests: XCTestCase {
    private let policy = HealthcheckPolicy(intervalSeconds: 5, timeoutSeconds: 2, retries: 3, startPeriodSeconds: 10)

    func testComposeDefaultsArePinned() {
        let d = HealthcheckPolicy.composeDefaults
        XCTAssertEqual(d.intervalSeconds, 30)
        XCTAssertEqual(d.timeoutSeconds, 30)
        XCTAssertEqual(d.retries, 3)
        XCTAssertEqual(d.startPeriodSeconds, 0)
        XCTAssertEqual(HealthcheckPolicy(nil), d)
    }

    func testPolicyFromHealthcheckParsesDurations() {
        let hc = Healthcheck(test: .cmdShell("x"), interval: "1m30s", timeout: "500ms", retries: 7, startPeriod: "2s")
        XCTAssertEqual(HealthcheckPolicy(hc), HealthcheckPolicy(intervalSeconds: 90, timeoutSeconds: 0.5, retries: 7, startPeriodSeconds: 2))
        XCTAssertNil(HealthcheckPolicy.seconds(duration: "5"))
        XCTAssertEqual(HealthcheckPolicy.seconds(duration: "1h"), 3600)
    }

    func testKindFromCondition() {
        let hc = Healthcheck(test: .cmdShell("x"))
        XCTAssertEqual(ReadinessKind.make(condition: .serviceStarted, healthcheck: hc), .started)
        XCTAssertEqual(ReadinessKind.make(condition: .serviceHealthy, healthcheck: nil), .started)
        XCTAssertEqual(ReadinessKind.make(condition: .serviceHealthy, healthcheck: Healthcheck(test: .none)), .started)
        XCTAssertEqual(ReadinessKind.make(condition: .serviceHealthy, healthcheck: hc), .healthy(.composeDefaults))
        // 初期化サービスは状態機械の対象外(前面実行の終了コードで決める)
        XCTAssertNil(ReadinessKind.make(condition: .serviceCompletedSuccessfully, healthcheck: hc))
    }

    func testStartedIsReadyImmediately() {
        var s = ReadinessSchedule(kind: .started, startedAt: 0)
        XCTAssertEqual(s.apply(.tick(at: 0)), .ready)
    }

    func testContainerExitFailsEveryKindAndNamesTheCodeOnlyWhenKnown() {
        var a = ReadinessSchedule(kind: .started, startedAt: 0)
        XCTAssertEqual(a.apply(.containerExited(code: 0, at: 1)), .failed(reason: "container exited with code 0 before it became ready"))
        var b = ReadinessSchedule(kind: .healthy(policy), startedAt: 0)
        XCTAssertEqual(b.apply(.containerExited(code: 1, at: 1)), .failed(reason: "container exited with code 1 before it became ready"))
        // Apple Container は終了コードを報告しない: 無い数字を書かない
        var c = ReadinessSchedule(kind: .healthy(policy), startedAt: 0)
        XCTAssertEqual(c.apply(.containerExited(code: nil, at: 1)), .failed(reason: "container exited before it became ready"))
        XCTAssertEqual(c.apply(.probeSucceeded(at: 2)), .failed(reason: "container exited before it became ready"))  // 終端は変わらない
    }

    func testHealthyProbesImmediatelyThenAfterInterval() {
        var s = ReadinessSchedule(kind: .healthy(policy), startedAt: 100)
        XCTAssertEqual(s.apply(.tick(at: 100)), .probe)
        XCTAssertEqual(s.apply(.tick(at: 100.5)), .wait(untilSeconds: 102))
        XCTAssertEqual(s.apply(.probeFailed(at: 101)), .wait(untilSeconds: 106))
        XCTAssertEqual(s.apply(.tick(at: 105)), .wait(untilSeconds: 106))
        XCTAssertEqual(s.apply(.tick(at: 106)), .probe)
        XCTAssertEqual(s.apply(.probeSucceeded(at: 106.2)), .ready)
        XCTAssertEqual(s.apply(.tick(at: 200)), .ready)
    }

    func testFailuresInsideStartPeriodAreNotCounted() {
        var s = ReadinessSchedule(kind: .healthy(policy), startedAt: 0)
        for t in [1.0, 3, 5, 7, 9] { _ = s.apply(.probeFailed(at: t)) }
        _ = s.apply(.probeFailed(at: 11))
        _ = s.apply(.probeTimedOut(at: 16))
        XCTAssertEqual(s.apply(.probeFailed(at: 21)), .failed(reason: "healthcheck failed 3 consecutive times"))
    }

    func testSuccessInsideStartPeriodIsReady() {
        var s = ReadinessSchedule(kind: .healthy(policy), startedAt: 0)
        XCTAssertEqual(s.apply(.probeSucceeded(at: 1)), .ready)
    }
}
