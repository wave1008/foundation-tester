// ft_launch の門(launchGuardDecision)の固定。未インストールのまま launch を撃つと
// XCUIApplication.launch() が返らずランナーが死ぬ(docs/verification.md)ため、
// 「確かめられない」を in-app/Android では素通し・それ以外では拒否に振り分ける規律を守る。

import XCTest
import FTBridgeClient
@testable import fleetest_mcp

final class LaunchInstallGuardTests: XCTestCase {

    private let bundleID = "com.example.myapp"

    /// unknown × iOS × xcuitest は撃たずに断る。文言に理由と bridge への言及が要る
    func testUnknownXCUITestRefuses() {
        guard let refusal = MCPServer.launchGuardDecision(
            verdict: .unknown("simctl get_app_container timed out"),
            isAndroid: false, engine: "xcuitest", bundleID: bundleID) else {
            return XCTFail("xcuitest では確かめられないなら断るべき")
        }
        XCTAssertTrue(refusal.contains("simctl get_app_container timed out"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("bridge"), refusal)
    }

    /// unknown × iOS × hybrid も断る(XCUITest 経路へ落ちうるので危険側)
    func testUnknownHybridRefuses() {
        XCTAssertNotNil(MCPServer.launchGuardDecision(
            verdict: .unknown("adb"), isAndroid: false, engine: "hybrid", bundleID: bundleID))
    }

    /// unknown × iOS × エンジン不明(nil)も断る(危険側)
    func testUnknownUnknownEngineRefuses() {
        XCTAssertNotNil(MCPServer.launchGuardDecision(
            verdict: .unknown("no device"), isAndroid: false, engine: nil, bundleID: bundleID))
    }

    /// unknown × iOS × in-app は撃つ(XCUIApplication.launch() を経由しないため危険が無い)
    func testUnknownInAppProceeds() {
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .unknown("simctl unavailable"), isAndroid: false, engine: "inapp", bundleID: bundleID))
    }

    /// unknown × Android はエンジンによらず撃つ(未インストールの launch がランナーを道連れにしない)
    func testUnknownAndroidProceeds() {
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .unknown("adb"), isAndroid: true, engine: nil, bundleID: bundleID))
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .unknown("adb"), isAndroid: true, engine: "xcuitest", bundleID: bundleID))
    }

    /// notInstalled は従来どおりの文言で断る
    func testNotInstalledRefusesWithExistingMessage() {
        let refusal = MCPServer.launchGuardDecision(
            verdict: .notInstalled, isAndroid: false, engine: "xcuitest", bundleID: bundleID)
        XCTAssertEqual(refusal, MCPServer.notInstalledMessage(bundleID: bundleID))
    }

    /// installed は常に撃つ
    func testInstalledProceeds() {
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .installed, isAndroid: false, engine: "xcuitest", bundleID: bundleID))
    }

    /// springboard は門を通らない(handleLaunch は launch せず参照するだけなのでランナーは死なない)
    func testSpringboardBypassesGateRegardlessOfVerdict() {
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .notInstalled, isAndroid: false, engine: "xcuitest",
            bundleID: "com.apple.springboard"))
        XCTAssertNil(MCPServer.launchGuardDecision(
            verdict: .unknown("no device"), isAndroid: false, engine: "xcuitest",
            bundleID: "com.apple.springboard"))
    }
}
