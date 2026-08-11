// awaitFocus(MCPServer+Dispatch.swift)の回帰テスト。タップ直後、対象欄へフォーカスが立つ前の
// Enter は前の欄へ飛ぶレースを防ぐための待ちで、これまでテストが無かった。
// ft_type(ref あり・text なし)= pressEnter 単独経路を dispatch 経由で確かめる。

import XCTest
import FTCore
@testable import ftester_mcp

private func focusTestElement(ref: Int, identifier: String, focused: Bool? = nil) -> ElementInfo {
    ElementInfo(ref: ref, type: "textField", identifier: identifier, label: nil, value: nil,
               placeholder: nil, enabled: true,
               frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1, focused: focused)
}

private func focusTestSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: 0)
}

final class MCPAwaitFocusTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// タップ後、対象へ focused が立つ台本 → 警告なし。1周目はまだ・2周目で立つ形にして
    /// ポーリングの継続も一緒に確かめる
    func testFocusLandsOnTheTargetGrantsWithoutWarning() async throws {
        driver.snapshotResponse = focusTestSnapshot([focusTestElement(ref: 1, identifier: "search_field",
                                                                      focused: false)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        driver.scriptedSnapshots = [
            // verifiedRef の fresh(まだ)
            focusTestSnapshot([focusTestElement(ref: 1, identifier: "search_field", focused: false)]),
            // awaitFocus 1周目(まだ)
            focusTestSnapshot([focusTestElement(ref: 1, identifier: "search_field", focused: false)]),
            // awaitFocus 2周目(立った)
            focusTestSnapshot([focusTestElement(ref: 1, identifier: "search_field", focused: true)]),
        ]
        let result = try await server.call(tool: "ft_type", args: ["ref": 1, "pressEnter": true])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertFalse(text.contains("never took focus"), text)
    }

    /// 対象に焦点が立たず**別の要素**が focused を持つ台本 → タイムアウト警告が応答に載る。
    /// 実時間 waitSeconds(1.5s)を払う(定数をテストから注入できないため許容)
    func testAnotherElementHoldingFocusTimesOutWithWarning() async throws {
        driver.snapshotResponse = focusTestSnapshot([
            focusTestElement(ref: 1, identifier: "search_field", focused: false),
            focusTestElement(ref: 2, identifier: "toolbar_done", focused: true),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let result = try await server.call(tool: "ft_type", args: ["ref": 1, "pressEnter": true])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("never took focus"), text)
    }

    /// 木に focused が1つも無い台本(報告しないフレームワーク)→ 即進行・警告なし
    func testNoElementReportingFocusGivesUpImmediately() async throws {
        driver.snapshotResponse = focusTestSnapshot([
            focusTestElement(ref: 1, identifier: "search_field", focused: nil),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let start = Date()
        let result = try await server.call(tool: "ft_type", args: ["ref": 1, "pressEnter": true])
        let elapsed = Date().timeIntervalSince(start)

        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertFalse(text.contains("never took focus"), text)
        XCTAssertLessThan(elapsed, 1.0, "誰も focused を名乗らない木では即座に諦めること")
    }
}
