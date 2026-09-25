// 2026-09-25 の DSL / MCP 設計レビューで直した口:
// ft_launch / ft_clear_input の snapshotAfter・ft_batch の scroll: / swipePointToPoint・
// セッション状態の一本化(forgetDeviceState がフラグ類も捨てる)

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class MCPDesignReviewFixesTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - snapshotAfter

    func testLaunchWithSnapshotAfterReturnsTheTree() async throws {
        let text = body(try await server.call(
            tool: "ft_launch", args: ["bundleId": "com.example.app", "snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("Launched: com.example.app"), text)
        XCTAssertTrue(text.contains("id=login_btn"), "木が付いていない: \(text)")
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("launch(") }.count, 1)
    }

    func testLaunchWithoutSnapshotAfterStaysTextOnly() async throws {
        let text = body(try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"]))
        XCTAssertFalse(text.contains("id=login_btn"), text)
    }

    func testClearInputWithSnapshotAfterReturnsTheTree() async throws {
        let text = body(try await server.call(tool: "ft_clear_input", args: ["snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("clearInput sent"), text)
        XCTAssertTrue(text.contains("id=login_btn"), "木が付いていない: \(text)")
    }

    // MARK: - ft_batch の scroll: / swipePointToPoint

    func testBatchTapWithScrollSearchesAndDraftsTheSameLine() async throws {
        let text = body(try await server.call(
            tool: "ft_batch", args: ["steps": "tap '#login_btn' scroll: .down maxSwipes: 3"]))
        XCTAssertTrue(text.contains("All 1 step(s) passed"), text)
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\", scroll: .down, maxSwipes: 3)"), draft)
    }

    func testBatchMaxSwipesWithoutScrollIsRefused() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn' maxSwipes: 3"])
            XCTFail("scroll: の無い maxSwipes: が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scroll:"), error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    func testBatchScrollWithoutASelectorIsRefused() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "type 'abc' scroll: .down"])
            XCTFail("セレクタ無しの scroll: が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs a selector"), error.localizedDescription)
        }
    }

    func testBatchNoScrollIsTheSameAsOmitting() async throws {
        _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn' scroll: .noScroll"])
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\")"), draft)
    }

    func testBatchRunsSwipePointToPoint() async throws {
        let text = body(try await server.call(
            tool: "ft_batch",
            args: ["steps": "swipePointToPoint startX: 200 startY: 550 endX: 200 endY: 250 durationSeconds: 0.3"]))
        XCTAssertTrue(text.contains("All 1 step(s) passed"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("drag(200.0,550.0->200.0,250.0") }, "\(driver.calls)")
    }

    /// 操作系の waitSeconds は値があれば必ず書き戻す(省略時は 5 秒ではなく約 0.7 秒なので、5 を省くと意味が変わる)。
    /// 往復テストは書き戻し同士を比べるので、両側で同じく落とすとこの誤りを見逃す = ここで直接見る
    func testActionWaitSecondsIsAlwaysWrittenBack() {
        let selector = FTSelector.parse("#a")
        for action in ["tap", "clearInput", "doubleTap"] {
            let line = ScenarioCodeGen.command(
                for: FlowStep(action: action, locator: selector.primary, timeout: 5)) ?? ""
            XCTAssertTrue(line.contains("waitSeconds: 5"), line)
        }
        let typed = ScenarioCodeGen.command(
            for: FlowStep(action: "type", locator: selector.primary, text: "x", timeout: 5)) ?? ""
        XCTAssertTrue(typed.contains("waitSeconds: 5"), typed)
    }

    // MARK: - 待ち上限は waitSeconds(DSL と同じ名前)

    /// 3経路とも渡した waitSeconds を読むこと。外れた回の文言に出る秒数で見る
    /// (別の名前を読むと既定の 5 秒に化け、文言は "5s" になる)
    func testFtSnapshotWaitForHonoursWaitSeconds() async throws {
        let text = body(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "#never_appears", "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("did not appear within 0s"), text)
    }

    func testSnapshotAfterWaitForHonoursWaitSeconds() async throws {
        let text = body(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "#never_appears", "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("did not appear within 0s"), text)
    }

    func testWaitForChangeHonoursWaitSeconds() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitForChange": true, "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("timed out after 0s"), text)
    }

    // MARK: - セッション状態

    /// 束ねる前は Set<String> の2つが forgetDeviceState の外にあった(前の機の状態が残っていた)
    func testForgetDeviceStateAlsoDropsTheFlags() {
        let key = MCPServer.engineKey([:])
        server.backgroundedByNavigate.insert(key)
        server.webPageCeilingLatched.insert(key)
        server.systemAlertProbePending.insert(key)
        server.forgetDeviceState(key)
        XCTAssertFalse(server.backgroundedByNavigate.contains(key))
        XCTAssertFalse(server.webPageCeilingLatched.contains(key))
        XCTAssertFalse(server.systemAlertProbePending.contains(key))
        XCTAssertNil(server.sessions[key])
    }
}
