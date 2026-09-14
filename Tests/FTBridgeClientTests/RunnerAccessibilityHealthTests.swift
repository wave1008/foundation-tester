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
}
