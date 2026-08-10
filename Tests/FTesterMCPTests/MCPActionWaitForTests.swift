// ft_tap/ft_type の snapshotAfter に waitFor/timeout を追加した分の検証(2026-08-10)。
// waitFor 付きは settle-lite(操作前後の見分けが付かないときだけ1回再読む)の代わりに、
// ft_snapshot と同じ待ちのロジック(MCPServer.waitFor)を使う。両者は排他 —— waitFor が
// あれば settle-lite は動かさない(snapshotAfterBody 参照)。

import XCTest
import FTCore
@testable import ftester_mcp

private func waitElement(ref: Int, type: String = "staticText", id: String? = nil,
                         label: String? = nil,
                         x: Double = 10, y: Double = 20,
                         w: Double = 100, h: Double = 40) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
               placeholder: nil, enabled: true,
               frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
}

private func waitSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: 0)
}

final class MCPActionWaitForTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// snapshotAfter + waitFor: 操作直後にはまだ無く、1回のポーリングで現れる要素を
    /// 待ってから木を返す(settle-lite の再読とは別経路 — sleep は waitPollSeconds 分だけ)
    func testSnapshotAfterWithWaitForWaitsForADelayedElement() async throws {
        let notYet = waitSnapshot([waitElement(ref: 1, id: "existing_row")])
        let appeared = waitSnapshot([waitElement(ref: 1, id: "existing_row"),
                                     waitElement(ref: 2, id: "candidate_row", label: "候補1")])
        driver.scriptedSnapshots = [notYet, appeared]

        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "#candidate_row", "timeout": 2.0]))
        XCTAssertTrue(text.contains("waitFor \"#candidate_row\" appeared"), text)
        XCTAssertTrue(text.contains("id=candidate_row"), text)
        XCTAssertFalse(text.contains("still looked unchanged"), text)
    }

    /// 満額待っても現れない → ft_snapshot と同じ「did not appear」note を出しつつ、
    /// 木は(待っている間の最新)を返す(throw しない)
    func testSnapshotAfterWithWaitForReportsATimeoutButStillReturnsTheTree() async throws {
        driver.snapshotResponse = waitSnapshot([waitElement(ref: 1, id: "existing_row")])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "#never_appears", "timeout": 0.1]))
        XCTAssertTrue(text.contains("did not appear within"), text)
        XCTAssertTrue(text.contains("id=existing_row"), text)
    }

    /// waitFor だけ渡して snapshotAfter を渡さない → 操作は実行したうえで、
    /// 待たなかったことを note する(throw しない — 操作自体は成功している)
    func testWaitForWithoutSnapshotAfterIsIgnoredWithANote() async throws {
        let content = try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "waitFor": "#never_appears"])
        let text = bodyText(content)
        XCTAssertTrue(text.contains("tap (1.0, 2.0) done"), text)
        XCTAssertTrue(text.contains("waitFor requires snapshotAfter: true"), text)
        // 待っていない(driver.calls に snapshot が積まれない — tap 1コールだけ)
        XCTAssertFalse(driver.calls.contains("snapshot"), "\(driver.calls)")
    }

    /// waitFor 未指定なら従来どおり settle-lite(操作前後が見分け付かないときだけ再読)のまま
    func testWithoutWaitForSettleLiteStillRuns() async throws {
        let same = waitSnapshot([waitElement(ref: 1, id: "login_btn")])
        driver.scriptedSnapshots = [same, same, same]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("still looked unchanged"), text)
    }

    /// ft_type でも同じ waitFor 分岐を通る(スキーマの追随漏れが無いことの配線確認)
    func testFtTypeAlsoSupportsWaitFor() async throws {
        let notYet = waitSnapshot([waitElement(ref: 1, type: "textField", id: "search_field")])
        let appeared = waitSnapshot([waitElement(ref: 1, type: "textField", id: "search_field"),
                                     waitElement(ref: 2, id: "result_row", label: "結果1")])
        driver.scriptedSnapshots = [notYet, appeared]

        let text = bodyText(try await server.call(
            tool: "ft_type", args: ["ref": 1, "text": "query", "snapshotAfter": true,
                                    "waitFor": "#result_row", "timeout": 2.0]))
        XCTAssertTrue(text.contains("waitFor \"#result_row\" appeared"), text)
        XCTAssertTrue(text.contains("id=result_row"), text)
    }
}
