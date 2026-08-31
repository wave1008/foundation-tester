// verifiedRef の覆い探針(screenNotRepresentedWarning)を撃つたびに聞き直さない(2026-08-31 F節)。
//
// `verifiedRef` は ref を撃つ直前の照合のたびに、最大3往復(/systemalert →
// /systemui/covering → /hittable)を払っていた(MCPRefGuardTests の
// testTapRetargetsToTheFreshRefWhenTheElementMoved が固定している系列参照)。連打で同じ画面を
// 撃つだけの探索でも、そのたびに全部払っていた。撮り直した木の指紋(StaleFrameDetector と同じ
// 判定)が前回と変わっていなければ、答えを使い回す。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPSystemAlertProbeMemoTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    private func element(x: Double, label: String = "OK") -> ElementInfo {
        ElementInfo(ref: 1, type: "Button", identifier: "btn", label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: 20, width: 100, height: 40), depth: 1)
    }

    private func screen(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    /// **同じ木への2回目のタップは systemAlert を聞き直さない**
    func testTwoTapsOnAnIdenticalTreeProbeSystemAlertOnlyOnce() async throws {
        driver.snapshotResponse = screen([element(x: 10)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        XCTAssertEqual(driver.calls.filter { $0 == "systemAlert" }.count, 1, "\(driver.calls)")
    }

    /// **木が変われば(指紋が変われば)聞き直す**。健全性の上限はここまで —— 木が動けば必ず再確認する
    func testATapAfterTheFrameChangesProbesSystemAlertAgain() async throws {
        driver.snapshotResponse = screen([element(x: 10)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        driver.snapshotResponse = screen([element(x: 50)])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        XCTAssertEqual(driver.calls.filter { $0 == "systemAlert" }.count, 2, "\(driver.calls)")
    }

    /// **キャッシュされた答えも実際の警告を運ぶ**: 出ているアラートは、探針を省略した2回目の
    /// 応答にも(使い回した記憶から)ちゃんと載る —— 省略が沈黙に化けない
    func testACachedAlertStillAppearsOnTheSecondReply() async throws {
        driver.snapshotResponse = screen([element(x: 10)])
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true, title: "何かのアラート", buttons: ["OK"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let first = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let second = try await server.call(tool: "ft_tap", args: ["ref": 1])

        XCTAssertTrue(Self.text(first).contains("a system alert"), Self.text(first))
        XCTAssertTrue(Self.text(second).contains("a system alert"), Self.text(second))
        XCTAssertEqual(driver.calls.filter { $0 == "systemAlert" }.count, 1, "\(driver.calls)")
    }
}
