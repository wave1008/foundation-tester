// 再利用する XCUITest ランナーの AX 劣化判定(RunnerAccessibilityHealth)。期待値はリテラル。

import XCTest
@testable import FTBridgeClient

final class RunnerAccessibilityHealthTests: XCTestCase {

    /// 閾値をリテラルで固定(正常 0.03〜0.27 秒 / 劣化 3.7〜4.1 秒の実測の間)
    func testThresholdIsPinned() {
        XCTAssertEqual(RunnerAccessibilityHealth.slowProbeSeconds, 2)
    }

    func testNormalProbeIsNotDegraded() {
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(probeSeconds: 0.05))
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(probeSeconds: 0.27))
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(probeSeconds: 1.99))
    }

    func testStaleRemoteElementLatencyIsDegraded() {
        XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(probeSeconds: 2))
        XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(probeSeconds: 3.7))
        XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(probeSeconds: 4.1))
    }

    /// 測れなかった回は劣化と言わない(不明を建て直しの根拠にしない)
    func testUnknownProbeIsNotDegraded() {
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(probeSeconds: nil))
    }

    func testInjectedPortsParse() {
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: ["FT_FAKE_SLOW_RUNNER_PORTS": "8123, 8125"]),
                       [8123, 8125])
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: [:]), [])
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: ["FT_FAKE_SLOW_RUNNER_PORTS": "x"]), [])
    }

    func testRestartMessageNamesTheMeasurementOrTheInjection() {
        let measured = RunnerAccessibilityHealth.restartMessage(name: "d", port: 8123, probeSeconds: 3.7, injected: false)
        XCTAssertTrue(measured.contains("3.7s"), measured)
        XCTAssertTrue(measured.contains("restarting it"), measured)
        let injected = RunnerAccessibilityHealth.restartMessage(name: "d", port: 8123, probeSeconds: nil, injected: true)
        XCTAssertTrue(injected.contains("FT_FAKE_SLOW_RUNNER_PORTS"), injected)
    }

    // MARK: - run 中の測り直しの門(shouldRecheck)

    /// 門の値は 2,000ms(劣化の閾値と同じ量)。境界の両側をリテラルで固定する
    func testRecheckGateIsTwoSecondsOfStepSnapshots() {
        XCTAssertFalse(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: 1999, injected: false))
        XCTAssertTrue(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: 2000, injected: false))
        XCTAssertTrue(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: 3741, injected: false))
    }

    /// 健全な run(ステップの snapshot が数十 ms)は 1 問も払わない
    func testHealthyStepsDoNotRecheck() {
        XCTAssertFalse(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: 68, injected: false))
    }

    /// 材料が無いシナリオ(dry-run・未計測のステップだけ)は測らない
    func testMissingStepTimingDoesNotRecheck() {
        XCTAssertFalse(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: nil, injected: false))
    }

    /// 注入されたポートは材料を問わず測る(陽性対照の口)
    func testInjectedPortAlwaysRechecks() {
        XCTAssertTrue(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: nil, injected: true))
        XCTAssertTrue(RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: 5, injected: true))
    }

    /// 建て直さなかった 1 行は、ステップの遅さと測った所要を並べるだけで帰属を言わない
    func testLeftRunningMessageStatesMeasurementsOnly() {
        let measured = RunnerAccessibilityHealth.leftRunningMessage(
            name: "iPhone 17 Pro-01", port: 8124, maxStepSnapshotMs: 2835, probeSeconds: 0.12)
        XCTAssertEqual(measured, "→ iPhone 17 Pro-01: a step spent 2835ms taking snapshots; the xcuitest"
            + " bridge on port 8124 answered a one-element accessibility query in 0.1s — left running")
        let unmeasured = RunnerAccessibilityHealth.leftRunningMessage(
            name: "iPhone 17 Pro-01", port: 8124, maxStepSnapshotMs: 2835, probeSeconds: nil)
        XCTAssertEqual(unmeasured, "→ iPhone 17 Pro-01: a step spent 2835ms taking snapshots; the xcuitest"
            + " bridge on port 8124 did not answer a one-element accessibility query (not measured) — left running")
    }

    // MARK: - 建て直しても直らなかった台(RunnerRestartFutility)

    func testFutilityIsRememberedPerUDIDUntilCleared() {
        let futility = RunnerRestartFutility()
        XCTAssertFalse(futility.contains(udid: "SIM-1"))
        futility.mark(udid: "SIM-1")
        XCTAssertTrue(futility.contains(udid: "SIM-1"))
        XCTAssertFalse(futility.contains(udid: "SIM-2"), "別の台には及ばない")
        futility.clear(udid: "SIM-1")
        XCTAssertFalse(futility.contains(udid: "SIM-1"), "測って健全なら忘れる")
    }

    /// 新しいランナーでも遅かった事実と、そこから言えること(ランナーのプロセスには無い)だけを言う
    func testRestartDidNotHelpMessage() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.restartDidNotHelpMessage(
                name: "iPhone 17 Pro-01", port: 8124, afterSeconds: 2.7),
            "⚠️ iPhone 17 Pro-01: the restarted xcuitest bridge on port 8124 still took 2.7s for a"
                + " one-element accessibility query (normal is under 0.3s), so the slowness is not in the"
                + " runner process — it is not restarted again in this run; rebooting the simulator is the"
                + " next thing to try")
    }

    func testKeptSlowRunnerMessage() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.keptSlowRunnerMessage(name: "iPhone 17 Pro-01", port: 8124),
            "→ iPhone 17 Pro-01: reusing the xcuitest bridge on port 8124 as it is"
                + " (restarting it did not help earlier in this process)")
    }

    // MARK: - 1 台のブリッジの実行順(BridgeProvisioner.executionOrder)

    /// hybrid は plan が in-app → xcuitest の順でも、実行は xcuitest → in-app
    func testXCUITestRunsBeforeInApp() {
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["inapp", "xcuitest"]), [1, 0])
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["xcuitest", "inapp"]), [0, 1])
    }

    func testSingleEngineKeepsItsIndex() {
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["inapp"]), [0])
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["xcuitest"]), [0])
    }

    // MARK: - 印を run をまたいで持ち越す(supplySlownessAction)

    /// 印なしは従来どおり
    func testNoMarkProceedsNormally() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(persisted: nil, hasForeignLease: false),
            .proceedNormally)
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(persisted: nil, hasForeignLease: true),
            .proceedNormally)
    }

    /// 印 = runnerRestartDidNotHelp かつリース無しは、シミュレータごと再起動する
    func testRunnerRestartFailedMarkWithoutLeaseRestartsTheSimulator() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(
                persisted: .runnerRestartDidNotHelp, hasForeignLease: false),
            .restartSimulator)
    }

    /// **変異②「lease がある台を除外しない」の陽性対照**: リースがあれば、印があっても
    /// 絶対にシミュレータへ触らない(reuseWithoutRestarting に倒れる)
    func testRunnerRestartFailedMarkWithLeaseNeverTouchesTheDevice() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(
                persisted: .runnerRestartDidNotHelp, hasForeignLease: true),
            .reuseWithoutRestarting)
    }

    /// 印 = simulatorRestartDidNotHelp は、リースの有無を問わず二度と触らない
    /// (シミュレータ再起動はもう試していないだけの話ではなく「試して効かなかった」ので)
    func testSimulatorRestartFailedMarkNeverRestartsAgain() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(
                persisted: .simulatorRestartDidNotHelp, hasForeignLease: false),
            .reuseWithoutRestarting)
        XCTAssertEqual(
            RunnerAccessibilityHealth.supplySlownessAction(
                persisted: .simulatorRestartDidNotHelp, hasForeignLease: true),
            .reuseWithoutRestarting)
    }

    // MARK: - リースの判定(hasForeignLease)

    func testNoHoldersIsNotForeign() {
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(
            runLeaseHolder: nil, mcpLeaseHolder: nil, selfPID: 100))
    }

    /// 自分自身が持つ run-lease は「使用中」に数えない(この run 自身が供給の中で自分の台に触るのは正常)
    func testOwnRunLeaseIsNotForeign() {
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(
            runLeaseHolder: 100, mcpLeaseHolder: nil, selfPID: 100))
    }

    /// **変異②の別角度**: 他プロセスの run-lease は必ず foreign
    func testAnotherProcessRunLeaseIsForeign() {
        XCTAssertTrue(RunnerAccessibilityHealth.hasForeignLease(
            runLeaseHolder: 999, mcpLeaseHolder: nil, selfPID: 100))
    }

    /// MCP の印(渡された時点で自分/親は除外済みという契約)は常に foreign
    func testMCPLeaseIsForeign() {
        XCTAssertTrue(RunnerAccessibilityHealth.hasForeignLease(
            runLeaseHolder: nil, mcpLeaseHolder: 555, selfPID: 100))
    }

    // MARK: - 新しい 1 行(印を run をまたいで持ち越す各メッセージ)

    func testRestartingSimulatorMessageNamesTheEarlierRun() {
        let text = RunnerAccessibilityHealth.restartingSimulatorMessage(name: "d", port: 8123)
        XCTAssertTrue(text.contains("an earlier run"), text)
        XCTAssertTrue(text.contains("rebooting the simulator"), text)
    }

    func testSimulatorRestartDidNotHelpMessageStatesTheMeasurementOnly() {
        let measured = RunnerAccessibilityHealth.simulatorRestartDidNotHelpMessage(
            name: "d", port: 8123, afterSeconds: 3.1)
        XCTAssertTrue(measured.contains("3.1s"), measured)
        XCTAssertTrue(measured.contains("nothing further is tried automatically"), measured)
        let unmeasured = RunnerAccessibilityHealth.simulatorRestartDidNotHelpMessage(
            name: "d", port: 8123, afterSeconds: nil)
        XCTAssertTrue(unmeasured.contains("an unmeasured amount of time"), unmeasured)
    }

    func testKeptAfterSimulatorRestartFailedMessage() {
        let text = RunnerAccessibilityHealth.keptAfterSimulatorRestartFailedMessage(name: "d", port: 8123)
        XCTAssertTrue(text.contains("rebooting the simulator did not help either"), text)
    }

    func testKeptBecauseLeasedMessage() {
        let text = RunnerAccessibilityHealth.keptBecauseLeasedMessage(name: "d", port: 8123)
        XCTAssertTrue(text.contains("another session is using this device"), text)
    }
}
