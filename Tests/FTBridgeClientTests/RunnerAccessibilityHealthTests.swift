// 再利用する XCUITest ランナーの AX 劣化判定(RunnerAccessibilityHealth)。期待値はリテラル。

import XCTest
import FTCore
@testable import FTBridgeClient

final class RunnerAccessibilityHealthTests: XCTestCase {

    /// 閾値をリテラルで固定(正常 0.03〜0.27 秒 / 劣化 3.7〜4.1 秒の実測の間)
    func testThresholdIsPinned() {
        XCTAssertEqual(RunnerAccessibilityHealth.slowProbeSeconds, 2)
    }

    func testNormalProbeIsNotDegraded() {
        for seconds in [0.05, 0.1, 0.27, 1.99] {
            XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(.answered(seconds)), "\(seconds)")
        }
    }

    func testStaleRemoteElementLatencyIsDegraded() {
        for seconds in [2, 2.0, 3.7, 4.1] {
            XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(.answered(seconds)), "\(seconds)")
        }
    }

    /// **答えなかったは最悪の劣化**(測れなかったではない)。実測: SpringBoard の AX 照会が 60 秒返らない端末
    /// (健全は 0.04 秒)を「不明」と読んで、供給の回復の階段が一度も動かなかった
    func testNoAnswerIsDegraded() {
        XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(.noAnswer(waited: 20)))
        XCTAssertTrue(RunnerAccessibilityHealth.isDegraded(.noAnswer(waited: 2)))
    }

    /// 測れなかった回(404・接続拒否・即切れ)は劣化と言わない(不明を起動し直しの根拠にしない)
    func testUnknownProbeIsNotDegraded() {
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(.unknown))
        XCTAssertFalse(RunnerAccessibilityHealth.isDegraded(nil))
    }

    /// 失敗した 1 問の分類: 届かなかった型で閾値以上待ったときだけ「答えなかった」。
    /// 即切れ(待った事実が無い)・届かなかった型でない失敗は不明
    func testFailureClassification() {
        XCTAssertEqual(RunnerAccessibilityHealth.classifyFailure(unreachable: true, waited: 20.1),
                       .noAnswer(waited: 20.1))
        XCTAssertEqual(RunnerAccessibilityHealth.classifyFailure(unreachable: true, waited: 2),
                       .noAnswer(waited: 2))
        XCTAssertEqual(RunnerAccessibilityHealth.classifyFailure(unreachable: true, waited: 1.99), .unknown)
        XCTAssertEqual(RunnerAccessibilityHealth.classifyFailure(unreachable: false, waited: 20), .unknown)
    }

    // MARK: - 起動し直しが効いたか(restartHelped)

    /// 直ったと言えるのは「答えて閾値未満」だけ。**答えなかった・測れなかったを成功に数えない**
    /// (測れなかった回復を成功にすると印が書かれず、次の run が同じ空振りを繰り返す)
    func testRestartHelpedOnlyWhenItAnsweredFast() {
        XCTAssertTrue(RunnerAccessibilityHealth.restartHelped(after: .answered(0.1)))
        XCTAssertTrue(RunnerAccessibilityHealth.restartHelped(after: .answered(1.99)))
        XCTAssertFalse(RunnerAccessibilityHealth.restartHelped(after: .answered(2)))
        XCTAssertFalse(RunnerAccessibilityHealth.restartHelped(after: .noAnswer(waited: 20)))
        XCTAssertFalse(RunnerAccessibilityHealth.restartHelped(after: .unknown))
    }

    // MARK: - ワーカー復帰の門(shouldReviveWorker)

    func testReviveGateRefusesOnlyUnansweringDevices() {
        let futility = RunnerRestartFutility()
        XCTAssertTrue(RunnerAccessibilityHealth.shouldReviveWorker(udid: "SIM-1", futility: futility))
        futility.mark(udid: "SIM-1")  // 遅いだけ(起動し直しても直らなかった)は復帰させてよい
        XCTAssertTrue(RunnerAccessibilityHealth.shouldReviveWorker(udid: "SIM-1", futility: futility))
        futility.markUnanswering(udid: "SIM-1")
        XCTAssertFalse(RunnerAccessibilityHealth.shouldReviveWorker(udid: "SIM-1", futility: futility))
        XCTAssertTrue(RunnerAccessibilityHealth.shouldReviveWorker(udid: "SIM-2", futility: futility), "別の台には及ばない")
        XCTAssertTrue(RunnerAccessibilityHealth.shouldReviveWorker(udid: nil, futility: futility), "udid の無いワーカー(Android)")
        futility.clear(udid: "SIM-1")
        XCTAssertTrue(RunnerAccessibilityHealth.shouldReviveWorker(udid: "SIM-1", futility: futility), "測って健全なら忘れる")
    }

    func testMeasuredPhraseNeverPrintsZeroSecondsForNoAnswer() {
        let text = RunnerAccessibilityHealth.measuredPhrase(.noAnswer(waited: 20.2))
        XCTAssertEqual(text, "did not answer a one-element accessibility query within 20s")
        XCTAssertEqual(RunnerAccessibilityHealth.measuredPhrase(.answered(3.7)),
                       "answered a one-element accessibility query in 3.7s")
    }

    func testInjectedPortsParse() {
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: ["FT_FAKE_SLOW_RUNNER_PORTS": "8123, 8125"]),
                       [8123, 8125])
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: [:]), [])
        XCTAssertEqual(RunnerAccessibilityHealth.injectedSlowPorts(environment: ["FT_FAKE_SLOW_RUNNER_PORTS": "x"]), [])
    }

    func testRestartMessageNamesTheMeasurementOrTheInjection() {
        let measured = RunnerAccessibilityHealth.restartMessage(name: "d", port: 8123, probe: .answered(3.7), injected: false)
        XCTAssertTrue(measured.contains("3.7s"), measured)
        XCTAssertTrue(measured.contains("restarting it"), measured)
        let injected = RunnerAccessibilityHealth.restartMessage(name: "d", port: 8123, probe: nil, injected: true)
        XCTAssertTrue(injected.contains("FT_FAKE_SLOW_RUNNER_PORTS"), injected)
        let silent = RunnerAccessibilityHealth.restartMessage(name: "d", port: 8123, probe: .noAnswer(waited: 20), injected: false)
        XCTAssertTrue(silent.contains("did not answer a one-element accessibility query within 20s"), silent)
        XCTAssertFalse(silent.contains("0.0s"), silent)
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

    /// 起動し直さなかった 1 行は、ステップの遅さと測った所要を並べるだけで帰属を言わない
    func testLeftRunningMessageStatesMeasurementsOnly() {
        let measured = RunnerAccessibilityHealth.leftRunningMessage(
            name: "iPhone 17 Pro-01", port: 8124, maxStepSnapshotMs: 2835, probe: .answered(0.12))
        XCTAssertEqual(measured, "→ iPhone 17 Pro-01: a step spent 2835ms taking snapshots; the xcuitest"
            + " bridge on port 8124 answered a one-element accessibility query in 0.1s — left running")
        let unmeasured = RunnerAccessibilityHealth.leftRunningMessage(
            name: "iPhone 17 Pro-01", port: 8124, maxStepSnapshotMs: 2835, probe: .unknown)
        XCTAssertEqual(unmeasured, "→ iPhone 17 Pro-01: a step spent 2835ms taking snapshots; the xcuitest"
            + " bridge on port 8124 did not answer a one-element accessibility query (not measured) — left running")
    }

    // MARK: - 起動し直しても直らなかったデバイス(RunnerRestartFutility)

    func testFutilityIsRememberedPerUDIDUntilCleared() {
        let futility = RunnerRestartFutility()
        XCTAssertFalse(futility.contains(udid: "SIM-1"))
        futility.mark(udid: "SIM-1")
        XCTAssertTrue(futility.contains(udid: "SIM-1"))
        XCTAssertFalse(futility.contains(udid: "SIM-2"), "別の台には及ばない")
        futility.clear(udid: "SIM-1")
        XCTAssertFalse(futility.contains(udid: "SIM-1"), "測って健全なら忘れる")
    }

    /// SpringBoard とランナーを起こし直しても遅かった事実と、次の一手(シミュレータの再起動)だけを言う
    func testRestartDidNotHelpMessage() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.restartDidNotHelpMessage(
                name: "iPhone 17 Pro-01", port: 8124, after: .answered(2.7)),
            "⚠️ iPhone 17 Pro-01: after restarting SpringBoard (on a simulator) and the xcuitest bridge on"
                + " port 8124, it still took 2.7s for a one-element accessibility query (normal is under 0.3s)"
                + " — it is not restarted again in this run; rebooting the simulator is the next thing to try")
    }

    func testKeptSlowRunnerMessage() {
        XCTAssertEqual(
            RunnerAccessibilityHealth.keptSlowRunnerMessage(name: "iPhone 17 Pro-01", port: 8124),
            "→ iPhone 17 Pro-01: reusing the xcuitest bridge on port 8124 as it is"
                + " (restarting it did not help earlier in this process)")
    }

    // MARK: - 1 台のブリッジの実行順(BridgeProvisioner.executionOrder)

    /// inapp モードは plan が in-app → xcuitest の順でも、実行は xcuitest → in-app
    func testXCUITestRunsBeforeInApp() {
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["inapp", "xcuitest"]), [1, 0])
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["xcuitest", "inapp"]), [0, 1])
    }

    func testSingleBridgeKeepsItsIndex() {
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["inapp"]), [0])
        XCTAssertEqual(BridgeProvisioner.executionOrder(of: ["xcuitest"]), [0])
    }

    // MARK: - 印を run をまたいで持ち越す(supplySlownessAction)

    private func action(_ persisted: RunnerSlowness?, lease: Bool, canWipe: Bool)
        -> RunnerAccessibilityHealth.SupplySlownessAction {
        RunnerAccessibilityHealth.supplySlownessAction(persisted: persisted, hasForeignLease: lease, canWipe: canWipe)
    }

    /// 印なしは従来どおり(リースにも初期化の可否にも依らない)
    func testNoMarkProceedsNormally() {
        for lease in [false, true] {
            for canWipe in [false, true] {
                XCTAssertEqual(action(nil, lease: lease, canWipe: canWipe), .proceedNormally)
            }
        }
    }

    /// 印 = runnerRestartDidNotHelp かつリース無しは、初期化の可否に依らずシミュレータの再起動から始める
    /// (初期化してよいかは、再起動で直らなかった後に escalateStuckRunner が見る)
    func testRunnerRestartFailedMarkWithoutLeaseRestartsTheSimulator() {
        XCTAssertEqual(action(.runnerRestartDidNotHelp, lease: false, canWipe: true), .restartSimulator)
        XCTAssertEqual(action(.runnerRestartDidNotHelp, lease: false, canWipe: false), .restartSimulator)
    }

    /// **リースがあれば、どの印でも絶対にシミュレータへ触らない**(再起動も初期化も)
    func testLeaseNeverTouchesTheDevice() {
        for persisted in [RunnerSlowness.runnerRestartDidNotHelp, .simulatorRestartDidNotHelp, .wipeDidNotHelp] {
            for canWipe in [false, true] {
                XCTAssertEqual(action(persisted, lease: true, canWipe: canWipe), .reuseWithoutRestarting,
                               "\(persisted) canWipe=\(canWipe)")
            }
        }
    }

    /// 再起動でも直らなかった印(古い版が書いた印もここへ来る)は、初期化してよい状態なら初期化へ進む
    func testSimulatorRestartFailedMarkGoesToTheWipe() {
        XCTAssertEqual(action(.simulatorRestartDidNotHelp, lease: false, canWipe: true), .wipeSimulator)
    }

    /// 初期化してよい状態でなければ(実機・アプリを入れ直さない供給)触らずそのまま使う
    func testSimulatorRestartFailedMarkWithoutWipePermissionReusesAsIs() {
        XCTAssertEqual(action(.simulatorRestartDidNotHelp, lease: false, canWipe: false), .reuseWithoutRestarting)
    }

    /// 初期化しても直らなかった印は終端: 何も自動で撃たない
    func testWipeFailedMarkIsTerminal() {
        XCTAssertEqual(action(.wipeDidNotHelp, lease: false, canWipe: true), .reuseWithoutRestarting)
        XCTAssertEqual(action(.wipeDidNotHelp, lease: false, canWipe: false), .reuseWithoutRestarting)
    }

    // MARK: - 初期化してよいか(wipeBlock)

    func testWipeBlockNamesTheFirstUnmetPrecondition() {
        XCTAssertNil(RunnerAccessibilityHealth.wipeBlock(isSimulator: true, hasForeignLease: false, runReinstallsApp: true))
        XCTAssertEqual(RunnerAccessibilityHealth.wipeBlock(isSimulator: false, hasForeignLease: false, runReinstallsApp: true),
                       .physicalDevice)
        XCTAssertEqual(RunnerAccessibilityHealth.wipeBlock(isSimulator: true, hasForeignLease: true, runReinstallsApp: true),
                       .foreignLease)
        XCTAssertEqual(RunnerAccessibilityHealth.wipeBlock(isSimulator: true, hasForeignLease: false, runReinstallsApp: false),
                       .appNotReinstalled)
        // 実機は他の条件に依らず断る
        XCTAssertEqual(RunnerAccessibilityHealth.wipeBlock(isSimulator: false, hasForeignLease: true, runReinstallsApp: false),
                       .physicalDevice)
    }

    func testWipeSkippedMessageOffersTheManualCommand() {
        for block in [RunnerAccessibilityHealth.WipeBlock.physicalDevice, .foreignLease, .appNotReinstalled] {
            let text = RunnerAccessibilityHealth.wipeSkippedMessage(name: "d", udid: "UDID-1", block: block)
            XCTAssertTrue(text.contains("`fleetest api wipe-device --platform ios --udid UDID-1`"), text)
        }
    }

    func testErasingMessageStatesTheMeasurementAndWhatIsDeleted() {
        let text = RunnerAccessibilityHealth.erasingSimulatorMessage(
            name: "d", port: 8123, after: .noAnswer(waited: 20), afterReboot: true)
        XCTAssertEqual(text, "⚠️ d: the xcuitest bridge on port 8123 still did not answer a one-element accessibility"
            + " query within 20s after rebooting the simulator — erasing the simulator (its apps and data are"
            + " deleted; the app under test is reinstalled by this run)")
    }

    // MARK: - リースの判定(hasForeignLease)

    func testNoHoldersIsNotForeign() {
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(
            runLeaseHolder: nil, mcpLeaseHolder: nil, selfPID: 100))
    }

    /// 自分自身が持つ run-lease は「使用中」に数えない(この run 自身が供給の中で自分のデバイスに触るのは正常)
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
            name: "d", port: 8123, after: .answered(3.1))
        XCTAssertTrue(measured.contains("3.1s"), measured)
        XCTAssertTrue(measured.contains("not erased now"), measured)
        let unmeasured = RunnerAccessibilityHealth.simulatorRestartDidNotHelpMessage(
            name: "d", port: 8123, after: nil)
        XCTAssertTrue(unmeasured.contains("could not be measured"), unmeasured)
    }

    func testKeptAfterSimulatorRestartFailedMessage() {
        let text = RunnerAccessibilityHealth.keptAfterSimulatorRestartFailedMessage(name: "d", port: 8123)
        XCTAssertTrue(text.contains("rebooting the simulator did not help"), text)
    }

    func testKeptBecauseLeasedMessage() {
        let text = RunnerAccessibilityHealth.keptBecauseLeasedMessage(name: "d", port: 8123)
        XCTAssertTrue(text.contains("another session is using this device"), text)
    }
}
