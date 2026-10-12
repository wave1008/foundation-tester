// MCP が覚える UI フレームワークの判定は「判定したアプリ」と組で持つ(DeviceSession.uiFrameworkHint)。
// 同じ端末で別のアプリへ替えた後に前のアプリの判定を使うと、RN に Compose の空打ちを撃って
// ft_scroll_to が行を開いた(実機 iPhone SE3: CMP → RN の順に起動)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class UIFrameworkHintBundleTests: XCTestCase {

    private func server(_ driver: FakeDriver) -> MCPServer {
        MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
    }

    /// 別のアプリの判定を、いま前面のアプリの答えとして返さない
    func testExecutorHintsIgnoreAHintOfAnotherApp() async {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(ready: true, device: "iPhone SE", osVersion: "26.6",
                                               sessionBundleID: "com.example.rn")
        let server = server(driver)
        let key = MCPServer.engineKey([:])
        server.uiFrameworkHints[key] = UIFrameworkHint(bundleID: "com.example.cmp", framework: .compose)
        let hints = await server.resolveExecutorHints(driver, args: [:])
        XCTAssertNotEqual(hints.uiFrameworkHint, .compose, "CMP の判定を RN の答えにした")
    }

    /// 同じアプリなら覚えた判定をそのまま使う(問い直さない)
    func testExecutorHintsReuseTheHintOfTheSameApp() async {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(ready: true, device: "iPhone SE", osVersion: "26.6",
                                               sessionBundleID: "com.example.cmp")
        let server = server(driver)
        let key = MCPServer.engineKey([:])
        server.uiFrameworkHints[key] = UIFrameworkHint(bundleID: "com.example.cmp", framework: .compose)
        let hints = await server.resolveExecutorHints(driver, args: [:])
        XCTAssertEqual(hints.uiFrameworkHint, .compose)
    }

    /// エンジンの助言も、起動したアプリが判定と別なら「不明」の形(もしこのフレームワークなら)に弱める
    func testEngineHintTreatsAHintOfAnotherLaunchedAppAsUnknown() {
        let server = server(FakeDriver())
        let key = MCPServer.engineKey([:])
        server.engines[key] = "xcuitest"
        server.uiFrameworkHints[key] = UIFrameworkHint(bundleID: "com.example.cmp", framework: .compose)
        server.launchedBundleIDs[key] = "com.example.rn"
        let hint = server.iosEngineHint("Compose Multiplatform", frameworkKey: .compose,
                                        "double tap", args: [:])
        XCTAssertTrue(hint.contains("this is a Compose Multiplatform app"),
                      "別のアプリの判定で断定した: \(hint)")
    }
}
