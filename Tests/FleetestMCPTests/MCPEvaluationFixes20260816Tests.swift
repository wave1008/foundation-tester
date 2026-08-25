// 4人目の外部評価(2026-08-16。マップで赤羽→立川の経路を調べるタスクの呼び出しコスト計測)。
// 指摘は4件で、実バグは0・**既にある機能が払った場所で名乗っていない**形が3件だった:
//
// ⒜ 「waitFor のタイムアウトは5秒固定」と読まれた —— `timeout` は 2026-08-10 から全ての待ちに
//    あるのに、**外れた回の文がどこにもそれを名指していなかった**。外れると分かっている待ちに
//    毎回満額(実測 5s × 2回)を払っていた
// ⒝ ft_scroll_to のシート展開救済を機械で判定したい —— 散文は出ていたが所要時間の内訳
//    (`sheet-expand rescue +1.4s`)と語が違い、1つの文字列で拾えなかった
// ⒞ interactiveOnly の継承を毎回明示してほしい —— snapshotAfter は既に名乗っていたが、
//    **ft_scroll_to は継承そのものをしていなかった**(黙って全行を返していた)
// ⒟ ft_type replace: true が素の type の約2倍(6.1s 対 2.3s)—— 仕様どおり(clear の1往復 +
//    打った結果の読み返し)。スキーマに値段と二重払いの避け方を書いた(ここでは検証しない)

import XCTest
import FTCore
@testable import fleetest_mcp

private func evalElement(ref: Int, type: String = "Button", id: String? = nil,
                         label: String? = nil, y: Double = 20) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                placeholder: nil, enabled: true,
                frame: FTRect(x: 10, y: y, width: 100, height: 40), depth: 1)
}

private func evalSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: 0)
}

// MARK: - ⒜ 待ちが外れた回は、その場で上限の変え方を名指しする

final class MCPWaitTimeoutRemedyTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        driver.snapshotResponse = evalSnapshot([evalElement(ref: 1, id: "login_btn", label: "ログイン")])
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testFtSnapshotWaitForMissNamesTheTimeoutArgument() async throws {
        let text = body(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "#never_appears", "timeout": 0.0]))
        XCTAssertTrue(text.contains("did not appear within"), text)
        XCTAssertTrue(text.contains("timeout: <seconds> sets this cap"), text)
    }

    /// 操作系の snapshotAfter 側にも同じ逃げ道が要る(評価で払われたのはこちら)
    func testSnapshotAfterWaitForMissNamesTheTimeoutArgument() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true,
                                   "waitFor": "#never_appears", "timeout": 0.0]))
        XCTAssertTrue(text.contains("did not appear within"), text)
        XCTAssertTrue(text.contains("timeout: <seconds> sets this cap"), text)
    }

    /// waitForChange の打ち切りも同じ上限を使うので、同じ逃げ道を出す
    func testWaitForChangeTimeoutNamesTheTimeoutArgument() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true,
                                   "waitForChange": true, "timeout": 0.0]))
        XCTAssertTrue(text.contains("waitForChange timed out"), text)
        XCTAssertTrue(text.contains("timeout: <seconds> sets this cap"), text)
    }

    /// 当たった回には出さない(逃げ道は払った場所だけで言う)
    func testASuccessfulWaitDoesNotCarryTheRemedy() async throws {
        let text = body(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "#login_btn", "timeout": 0.0]))
        XCTAssertFalse(text.contains("timeout: <seconds>"), text)
    }

    /// 秒の印字は `5.0s` ではなく `5s`(既定値の桁が増えるだけで情報が無い)。
    /// 端数は残す —— `0.5s` を `0s`/`1s` と丸めると、渡した値と違う数字を見せることになる
    func testSecondsTextDropsTheTrailingZeroButKeepsFractions() {
        XCTAssertEqual(MCPServer.secondsText(5), "5s")
        XCTAssertEqual(MCPServer.secondsText(0), "0s")
        XCTAssertEqual(MCPServer.secondsText(0.5), "0.5s")
    }
}

// MARK: - ⒝ シート展開救済は、起きたことと値段を同じ語で拾える

final class MCPSheetRescueMarkerTests: XCTestCase {

    private static func snapshotSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Snapshot.swift"), encoding: .utf8)
    }

    /// **1つの文字列で「起きたか」と「いくらかかったか」の両方が拾える**こと。
    /// 別々の語にすると、呼び出し元は救済の検出と所要時間の検出に2つのパターンを持つことになる
    func testTheMarkerIsTheSameWordAsTheTimingBreakdown() {
        let timing = MCPServer.scrollTimingNote(totalMs: 3000, swipes: 2, rescueMs: 1400)
        XCTAssertTrue(timing.contains("sheet-expand rescue"), timing)
        XCTAssertTrue(MCPServer.sheetRescueMarker.contains("sheet-expand rescue"),
                      MCPServer.sheetRescueMarker)
    }

    /// **ソース走査**: 救済の4形(記憶で省いた / 伸びなかった / 展開だけで出た / 再試行した)が
    /// すべてマーカー経由であること。1つでも生リテラルに戻ると、その形だけ機械判定から漏れる
    /// —— 漏れたことは応答を読まない限り分からない(注記は出ているので、見た目は正常)
    func testEveryRescueNoteGoesThroughTheMarker() throws {
        let source = try Self.snapshotSource()
        let assignments = source.components(separatedBy: "\n")
            .filter { $0.contains("sheetNote = ") && !$0.contains("var sheetNote") }
        XCTAssertEqual(assignments.count, 4,
                       "救済の形が増減した。増やしたならマーカー経由にしてこの数を更新する:"
                       + " \(assignments)")
        for line in assignments {
            XCTAssertTrue(line.contains("Self.sheetRescueMarker"),
                          "マーカーを通っていない救済の注記がある: \(line)")
        }
    }
}

// MARK: - ⒞ 木を返す口はすべて同じ畳み方を継承し、継承したことを名乗る

final class MCPScrollToFilterInheritanceTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = evalSnapshot([
            evalElement(ref: 1, id: "login_btn", label: "ログイン"),
            // ラベル・値の無い other = interactiveOnly が隠すレイアウト専用行
            evalElement(ref: 2, type: "other", id: "spacer", y: 70),
        ])
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// ft_snapshot で明示した interactiveOnly: true が ft_scroll_to の一覧にも効き、名乗る。
    /// 直っていないと、読み手が出力量を絞ったつもりのセッションで**ツールによって量が変わる**
    func testScrollToInheritsInteractiveOnlyAndSaysSo() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let text = body(try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"]))
        XCTAssertFalse(text.contains("id=spacer"), text)
        XCTAssertTrue(
            text.contains("interactiveOnly: true inherited from your last ft_snapshot"), text)
    }

    /// 明示した値が常に優先(snapshotAfter 側と同じ規則)
    func testExplicitValueOverridesTheInheritance() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let text = body(try await server.call(
            tool: "ft_scroll_to", args: ["selector": "#login_btn", "interactiveOnly": false]))
        XCTAssertTrue(text.contains("id=spacer"), text)
        XCTAssertFalse(text.contains("inherited from your last ft_snapshot"), text)
    }

    /// 記憶が無ければ黙る(継承の宣言が常時出る = 雑音になるのを防ぐ陰性対照)
    func testNoMemoryMeansNoNoteAndNoFiltering() async throws {
        let text = body(try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"]))
        XCTAssertTrue(text.contains("id=spacer"), text)
        XCTAssertFalse(text.contains("inherited from your last ft_snapshot"), text)
    }
}
