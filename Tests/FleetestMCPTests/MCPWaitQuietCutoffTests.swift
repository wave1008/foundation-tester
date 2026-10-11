// waitFor の空振りを、木が `waitForQuietCutoffSeconds` 変わらなければ上限より前に切り上げる。
// 外れたセレクタ(AI が表記を推測で外した)を上限まで待っていた(実測: 地図の計測で空振り15回・各7〜12秒)。
// 部分一致が見えた待ち・読み込み中の印がある待ち・上限が切り上げの時間以下の待ちは、上限まで待つ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPWaitQuietCutoffTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, label: String? = nil, scrollable: Bool? = nil,
                         y: Double = 100, h: Double = 44) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: y, width: 402, height: h), depth: 1)
        e.scrollable = scrollable
        return e
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    /// 根拠(正しい待ちの最長 0.9 秒・わざと遅らせた画面 2.0 秒)より長いこと。値はリテラルで固定する
    func testTheCutoffIsPinned() {
        XCTAssertEqual(MCPServer.waitForQuietCutoffSeconds, 3.0)
    }

    func testCutoffAppliesOnlyWithoutPartialMatchLoadingSignOrShortCap() {
        let plain = tree([element(1, "button", label: "計画")])
        XCTAssertTrue(MCPServer.quietCutoffApplies(cap: 8, partialSeen: false, latest: plain))
        XCTAssertFalse(MCPServer.quietCutoffApplies(cap: 8, partialSeen: true, latest: plain), "部分一致が見えたら上限まで")
        XCTAssertFalse(MCPServer.quietCutoffApplies(cap: 3, partialSeen: false, latest: plain), "上限が切り上げの時間以下")
        let loading = tree([element(1, "scrollView", scrollable: true, y: 100, h: 700)])   // 中身の無い大きなスクロール領域
        XCTAssertFalse(MCPServer.quietCutoffApplies(cap: 8, partialSeen: false, latest: loading), "読み込み中の印があれば待つ")
    }

    /// **動かない画面の空振りは上限より前に返り、切り上げたことを言う**(所要を直接測る)
    func testAStillScreenStopsBeforeTheCapAndSaysSo() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([element(1, "button", label: "計画")])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let started = Date()
        let result = try await server.call(tool: "ft_snapshot", args: ["waitFor": "*経路*", "waitSeconds": 8.0])
        let elapsed = Date().timeIntervalSince(started)
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertLessThan(elapsed, 6, "上限(8秒)まで待った")
        XCTAssertGreaterThanOrEqual(elapsed, MCPServer.waitForQuietCutoffSeconds, "切り上げの時間より前に返った")
        XCTAssertTrue(text.contains("the screen had not changed for 3s"), text)
        XCTAssertTrue(text.contains("waitForChange"), "読み込み中なら待つ手段を言うこと: \(text)")
    }

    /// 部分一致が見えた待ちは、従来どおり上限まで待つ(ローディングのプレースホルダの後に本命が来る画面)
    func testAPartialMatchStillWaitsToTheCap() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([element(1, "staticText", label: "経路を検索中")])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let started = Date()
        let result = try await server.call(tool: "ft_snapshot", args: ["waitFor": "経路", "waitSeconds": 3.6])
        let elapsed = Date().timeIntervalSince(started)
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertGreaterThanOrEqual(elapsed, 3.5, "部分一致が見えていたのに切り上げた: \(text)")
        XCTAssertFalse(text.contains("had not changed"), text)
    }

    /// **上限を跨いだ読みでは切り上げと言わない**(計測で "stopped after 5.1s instead of running to the 5s cap" と出た)。
    /// 読み1回に 0.8 秒かかる画面で上限 3.2 秒: 読みは 1.1 / 2.2 / 3.3 秒に終わり、静止 3 秒に届くのは上限を跨いだ読みだけ
    func testTheReadThatCrossesTheCapIsNotCalledACutoff() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([element(1, "button", label: "計画")])
        driver.snapshotDelaySeconds = 0.8
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let result = try await server.call(tool: "ft_snapshot", args: ["waitFor": "*経路*", "waitSeconds": 3.2])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(text.contains("had not changed"), text)
        XCTAssertTrue(text.contains("did not appear"), text)
    }
}
