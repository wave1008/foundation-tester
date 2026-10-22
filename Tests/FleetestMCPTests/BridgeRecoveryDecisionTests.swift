// MCP の xcuitest ブリッジ自動復帰(B1)の純粋な判定(MCPServer+BridgeRecovery.swift)。
// I/O(BridgeProvisioner.provision・RepoRoot.find 等)を挟まず判定材料だけで固定する。

import XCTest
@testable import fleetest_mcp

final class BridgeRecoveryDecisionTests: XCTestCase {

    // MARK: - shouldAttemptXCUITestBridgeRecovery

    func testRecoversOnlyForConnectionRefusedOnASimulatorXCUITestBridge() {
        XCTAssertTrue(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "xcuitest", alreadyFailedThisSession: false, isPhysical: false, heldByAnotherSession: false))
    }

    /// bridgeUnreachable(タイムアウト)等では起動し直さない——死んでいるとまだ確定していない
    func testDoesNotRecoverWhenTheErrorIsNotConnectionRefused() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: false, bridge: "xcuitest", alreadyFailedThisSession: false, isPhysical: false, heldByAnotherSession: false))
    }

    /// in-app ブリッジを含む構成(inapp モード)は起動し直しの単位が違う(対象アプリごと落ちる)ので対象外
    func testDoesNotRecoverInAppBridges() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "inapp", alreadyFailedThisSession: false, isPhysical: false, heldByAnotherSession: false))
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: nil, alreadyFailedThisSession: false, isPhysical: false, heldByAnotherSession: false))
    }

    /// 実機は provision() の対象外(isPhysical が true でも不明(nil)でも撃たない——
    /// 「分からない」を「シミュレータだ」と読んで実機へ provision を撃たない)
    func testDoesNotRecoverPhysicalOrUnidentifiedDevices() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "xcuitest", alreadyFailedThisSession: false, isPhysical: true, heldByAnotherSession: false))
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "xcuitest", alreadyFailedThisSession: false, isPhysical: nil, heldByAnotherSession: false))
    }

    /// このセッションで一度失敗した sessionKey は二度と試さない(無限リトライにしない)
    func testDoesNotRetryAfterAnEarlierFailureThisSession() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "xcuitest", alreadyFailedThisSession: true, isPhysical: false, heldByAnotherSession: false))
    }

    // MARK: - shouldAttemptXCUITestRunnerRecheck

    /// **起動の入口で撃つので所要の門は無い**: シミュレータの XCUITest なら常に1問測る(健全なら測るだけ)
    func testRechecksASimulatorXCUITestBridgeAtLaunch() {
        XCTAssertTrue(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "xcuitest", isPhysical: false, injected: false, heldByAnotherSession: false))
    }

    func testDoesNotRecheckInAppBridgesOrPhysicalDevices() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "inapp", isPhysical: false, injected: false, heldByAnotherSession: false))
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "xcuitest", isPhysical: true, injected: false, heldByAnotherSession: false))
    }

    /// 注入口(FT_FAKE_SLOW_RUNNER_PORTS)も同じ門を通る(陽性対照)
    func testInjectedAlwaysRechecksRegardlessOfElapsed() {
        XCTAssertTrue(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "xcuitest", isPhysical: false, injected: true, heldByAnotherSession: false))
    }

    // MARK: - 他のセッション(run・別の MCP)が使っているデバイス

    /// **他のセッションが使っているデバイスは起動し直さない**(2026-10-06 負荷テスト: MCP の自動回復が
    /// run の引き取ったシミュレータのランナーを作り直し、run のレーンが「status に応答しない」で脱落した)。
    /// 他の条件がすべて「撃つ」側に揃っていても、持ち主がいれば撃たない
    func testDoesNotRecoverADeviceHeldByAnotherSession() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: true, bridge: "xcuitest", alreadyFailedThisSession: false, isPhysical: false,
            heldByAnotherSession: true))
    }

    func testDoesNotRecheckADeviceHeldByAnotherSession() {
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "xcuitest", isPhysical: false, injected: false, heldByAnotherSession: true))
        XCTAssertFalse(MCPServer.shouldAttemptXCUITestRunnerRecheck(
            bridge: "xcuitest", isPhysical: false, injected: true, heldByAnotherSession: true))
    }
}
