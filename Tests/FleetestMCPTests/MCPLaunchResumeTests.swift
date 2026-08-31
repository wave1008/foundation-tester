// ft_launch resume: true(activate without terminating)。
//
// AppDriver.activate(bundleID:) は実装済み(BridgeClient → POST /session LaunchRequest(activate:
// true)・ランナー・Android も)だったが MCP は一度も呼んでいなかった。in-app/hybrid は
// activate に override が無く AppDriver の既定実装(= launch)へ落ちるので、そのまま resume を
// 通すと「resumed」と嘘をついて実際には毎回終了→起動する — その2エンジンだけ拒否する。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPLaunchResumeTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!
    private let key = MCPServer.engineKey([:])

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// **resume: true は activate を撃つ**(launch ではない)。既定エンジン(差し替えドライバは
    /// xcuitest を名乗る)なので拒否されない
    func testResumeCallsActivateNotLaunch() async throws {
        let result = try await server.call(
            tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
        XCTAssertEqual(driver.calls, ["activate(com.example.app)"])
        let message = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertEqual(message, "Activated: com.example.app (resumed without relaunching)")
    }

    /// resume を付けなければ従来どおり launch(退行が無いこと)
    func testWithoutResumeStillCallsLaunch() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        XCTAssertEqual(driver.calls, ["launch(com.example.app)"])
    }

    /// resume でも launchedBundleIDs は更新される(以後の switchedAppNote 判定の基準)
    func testResumeUpdatesLaunchedBundleIDs() async throws {
        _ = try await server.call(
            tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
        XCTAssertEqual(server.launchedBundleIDs[key], "com.example.app")
    }

    /// **in-app は activate に override が無く launch へ落ちる**ので resume を断る
    /// (ドライバへは一切触らない —— 撃ってから「実は違った」と言わない)
    func testResumeIsRefusedOnInAppEngine() async {
        server.engines[key] = "inapp"
        do {
            _ = try await server.call(
                tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
            XCTFail("inapp では resume を断るはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("xcuitest"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [])
    }

    /// hybrid も同じ(既定プロファイルのエンジン)
    func testResumeIsRefusedOnHybridEngine() async {
        server.engines[key] = "hybrid"
        do {
            _ = try await server.call(
                tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
            XCTFail("hybrid では resume を断るはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("xcuitest"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [])
    }

    /// **springboard の扱いは resume でも変わらない** —— アラートを読みに行く正規の経路なので
    /// systemAlertProbePending を立てない
    func testSpringboardRuleIsUnchangedForResume() async throws {
        _ = try await server.call(
            tool: "ft_launch", args: ["bundleId": "com.apple.springboard", "resume": true])
        XCTAssertEqual(driver.calls, ["activate(com.apple.springboard)"])
        XCTAssertFalse(server.systemAlertProbePending.contains(key))
    }
}
