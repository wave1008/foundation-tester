// SpringBoard への1問(`GET /systemalert`)が**失敗した**回を「アラート無し」に畳まない(§19 P2)。
// USB の token 無し・WiFi の待ち受け断・ランナーの死亡で照会が落ちると、`iosAlertHandler` を
// 登録したのにアラートへ吸われた操作が注記なしの緑になっていた(実機 SE3)。
// 規律: 操作は進める(新しい検知は警告から)が、注記 `system-alert-probe-failed` を立て、
// 失敗したステップは文言に理由を添える。**照会が通った回には出さない**(常に出す変異を落とす)

import XCTest
@testable import FTCore

final class SystemAlertProbeFailureTests: XCTestCase {
    private struct ProbeDown: Error, LocalizedError {
        var errorDescription: String? { "HTTP 401 unauthorized" }
    }

    private func button(ref: Int, _ id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 10, y: 100, width: 100, height: 40), depth: 1)
    }

    /// 登録あり(= 門が毎ステップ聞く)。fallback の照会を落とすかは引数
    private func makeExecutor(log: CallLog, probeFails: Bool,
                              registered: Bool = true) -> (StepExecutor, FakeAppDriver) {
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[button(ref: 1, "btn_freeze_3s")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        if probeFails { fallback.systemAlertError = ProbeDown() }
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        if registered {
            executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*写真*", button: "許可"))
        }
        return (executor, primary)
    }

    /// 登録があるのに照会が落ちた: 操作は撃つ(緑)が、確かめていないことを注記に残す
    func testRegisteredProbeFailureActsAndLeavesANote() async throws {
        let log = CallLog()
        let (executor, _) = makeExecutor(log: log, probeFails: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_freeze_3s"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { return XCTFail("操作は止めない: \(outcome.status)") }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.systemAlertProbeFailed), "\(outcome.notes)")
        XCTAssertTrue(log.entries.contains("fallback.systemAlert"), "門は聞いている: \(log.entries)")
    }

    /// 照会が通った(出ていない)回には注記を出さない
    func testASuccessfulProbeLeavesNoNote() async throws {
        let log = CallLog()
        let (executor, _) = makeExecutor(log: log, probeFails: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_freeze_3s"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(log.entries.contains("fallback.systemAlert"), "\(log.entries)")
        XCTAssertFalse(outcome.notes.contains(.systemAlertProbeFailed), "\(outcome.notes)")
    }

    /// 落ちたステップの文言に「確かめられなかった」を添える(登録あり)
    func testFailureMessageSaysTheCheckCouldNotBeMade() async throws {
        let log = CallLog()
        let (executor, _) = makeExecutor(log: log, probeFails: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_missing"), timeout: 0.2)

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("the check for a system alert in front of the app failed"
                                      + " (HTTP 401 unauthorized)"), reason)
        XCTAssertTrue(outcome.notes.contains(.systemAlertProbeFailed), "\(outcome.notes)")
    }

    /// 登録が無い回の失敗時の1問(`annotatedWithSystemAlert`)も同じ規律
    func testUnregisteredFailureProbeIsReportedToo() async throws {
        let log = CallLog()
        let (executor, _) = makeExecutor(log: log, probeFails: true, registered: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_missing"), timeout: 0.2)

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("so an alert could not be ruled out as the cause"), reason)
        XCTAssertTrue(outcome.notes.contains(.systemAlertProbeFailed), "\(outcome.notes)")
    }

    /// 登録が無く照会も通った失敗には添えない(常に添える変異を落とす)
    func testUnregisteredFailureWithAWorkingProbeStaysPlain() async throws {
        let log = CallLog()
        let (executor, _) = makeExecutor(log: log, probeFails: false, registered: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_missing"), timeout: 0.2)

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(reason.contains("could not be ruled out"), reason)
        XCTAssertFalse(outcome.notes.contains(.systemAlertProbeFailed), "\(outcome.notes)")
    }
}
