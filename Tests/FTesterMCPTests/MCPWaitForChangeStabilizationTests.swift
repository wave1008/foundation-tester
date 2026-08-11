// 2026-08-12 の実アプリ監査(赤羽→立川・ラウンド15)由来:
// waitForChange は「差が出た」だけで確定を返し、その木がネットワーク待ちの中間状態
// (検索の「候補なし」)でも読み手に最終形として渡っていた。修正は2段:
//   安定確認(差が出た後、直前の読みと一致するまで changeSettleRereads 回まで採り直す)
//   + 遷移を1度も観測していないとき(初回読みで既に差があった)の注意書き

import XCTest
import FTBridgeClient
import FTCore
@testable import ftester_mcp

final class MCPWaitForChangeStabilizationTests: XCTestCase {

    /// **初回読みで既に差があった**(遷移を観測していない): 中間状態かもしれない旨を注記する
    func testChangedOnFirstReadCarriesTheAsyncPopulationCaveat() async throws {
        let text = try await runWaitForChange(
            script: [Self.screen("base"), Self.screen("empty-intermediate")])
        XCTAssertTrue(text.contains("waitForChange: the tree differs"), text)
        XCTAssertTrue(text.contains("already present on the first read"), text)
    }

    /// **ポーリング中に遷移を観測した**: 注意書きは出さない(どこにでも付く注意は読み飛ばされる)
    func testTransitionObservedOnALaterPollDoesNotCarryTheCaveat() async throws {
        let text = try await runWaitForChange(
            script: [Self.screen("base"), Self.screen("base"), Self.screen("new")])
        XCTAssertTrue(text.contains("waitForChange: the tree differs"), text)
        XCTAssertFalse(text.contains("already present on the first read"), text)
    }

    /// **揺れたら採り直す**: 差が出た木が次の読みと食い違ったら新しい方を採り、そう言う
    func testChurnAdoptsTheLatestReadAndSaysSo() async throws {
        let text = try await runWaitForChange(
            script: [Self.screen("base"), Self.screen("intermediate"), Self.screen("final")])
        XCTAssertTrue(text.contains("kept changing after the first difference"), text)
        XCTAssertTrue(text.contains("final"), text)
        XCTAssertFalse(text.contains("already present on the first read"), text)
    }

    /// **上限まで揺れ続けた**: 整定していないかもしれないと言う(嘘の安定を作らない)
    func testStillChurningAfterTheCapSaysItMayNotHaveSettled() async throws {
        let script = [Self.screen("base")]
            + (0...MCPServer.changeSettleRereads).map { Self.screen("churn-\($0)") }
        let text = try await runWaitForChange(script: script)
        XCTAssertTrue(text.contains("still changing between re-reads"), text)
        XCTAssertTrue(text.contains("churn-\(MCPServer.changeSettleRereads)"), text)
        XCTAssertFalse(text.contains("kept changing after the first difference"), text)
    }

    /// 台本の先頭1枚を ft_snapshot で基準にし、残りを操作後の読みとして流す
    private func runWaitForChange(script: [SnapshotResponse]) async throws -> String {
        let driver = FakeDriver()
        driver.scriptedSnapshots = script
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0.01
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(
            tool: "ft_tap", args: ["x": 10.0, "y": 10.0, "snapshotAfter": true,
                                   "waitForChange": true])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private static func screen(_ label: String) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "staticText", identifier: "row",
                                                label: label, value: nil, placeholder: nil,
                                                enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 100, height: 40),
                                                depth: 1)],
                         truncatedCount: 0)
    }
}
