// 21回目の実アプリ監査(ブラウザ アーキタイプ)由来の MCP メッセージ/報告の欠陥3件:
//   ① setTextRefusedHint が「tap は既に実行済み」を言わず、再タップを勧めていた
//      (Android Chrome の擬似検索ボックス → 実入力欄への差し替えで二重の失敗を招いた)
//   ② waitFor タイムアウト文がスクロール圏外の可能性/操作無効の可能性を言わなかった
//      (Yahoo 天気で25秒2回=52秒を空費・tenki.jp でタップが効かないまま満額待った)
//   ③ ft_scroll_to が多重ヒットを黙っていた(tenki.jp で「2週間」タブに誤って命中)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPAuditRound21Tests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "other", id: String? = nil,
                         label: String? = nil, frame: FTRect, depth: Int = 1,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth,
                    scrollable: scrollable)
    }

    private func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - ① setTextRefusedHint: tap 済みを前提にする

    /// **本丸**: マーカーを含む 500 が返ったら、再タップを止め、ref なしでの撃ち直しを案内する
    /// (旧文言は「まず ft_tap しろ」で、ブリッジが既に tap を撃ち終えている事実と矛盾していた)
    func testSetTextRefusedHintAdvisesAgainstRetappingAndRetryingWithoutRef() {
        let hint = MCPServer.setTextRefusedHint(
            tool: "ft_type", args: ["ref": 42],
            message: "The driver returned an error (500): cannot type into the field that was"
                + " tapped (not focused (requesting focus with ACTION_CLICK), 4000ms waited)")
        XCTAssertTrue(hint.contains("already tapped"), hint)
        XCTAssertTrue(hint.contains("Do not re-tap"), hint)
        XCTAssertTrue(hint.contains("WITHOUT ref"), hint)
        // NumberPicker の事実は残す(既存の情報を消さない)
        XCTAssertTrue(hint.contains("NumberPicker"), hint)
    }

    /// マーカーの無い失敗・関係のないツール・**ref を渡していない ft_type**には出さない
    /// (ref なしの type は最初からタップを撃っていないので「既に tap 済み」は嘘になる)
    func testSetTextRefusedHintStaysQuietWithoutRefOrMarker() {
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_type", args: [:],
            message: "cannot type into the field that was tapped (…)"), "")
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_type", args: ["ref": 42], message: "bridge not running"), "")
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_tap", args: ["ref": 42],
            message: "cannot type into the field that was tapped (…)"), "")
    }

    // MARK: - ② waitFor: スクロール圏外の可能性

    /// **本丸**: スクロール容器が申告されている画面で waitFor が空振りしたら ft_scroll_to を案内する
    /// (実測: Yahoo 天気の週間予報表は初期表示の下にあり、waitFor を25秒×2=52秒空費した)
    func testWaitForTimeoutSuggestsScrollToWhenAScrollContainerExists() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), scrollable: true),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_snapshot",
                                            args: ["waitFor": "*週間天気*", "timeout": 0.0])
        let body = text(content)
        XCTAssertTrue(body.contains("waitFor only looks at what is currently rendered"), body)
        XCTAssertTrue(body.contains("use ft_scroll_to (it searches by scrolling)"), body)
    }

    /// **陰性対照**: スクロール容器が1つも申告されていない画面では出さない
    /// (その画面ではスクロールは答えになり得ない —— 誤検知を出さない側に倒す)
    func testWaitForTimeoutStaysSilentWithoutAScrollContainer() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snapshot([
            element(1, type: "button", id: "go", label: "検索",
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40)),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_snapshot",
                                            args: ["waitFor": "*週間天気*", "timeout": 0.0])
        let body = text(content)
        XCTAssertFalse(body.contains("waitFor only looks at what is currently rendered"), body)
        XCTAssertFalse(body.contains("use ft_scroll_to"), body)
    }

    /// **配線の同一性**: ft_snapshot(Dispatch)と snapshotAfter(Snapshot 側の ft_tap 経路)が
    /// 発する文が一字一句同じであること(片方だけ変わる事故を防ぐ共通ヘルパの検証)
    func testWaitForScrollHintIsIdenticalAcrossBothWaitForSites() async throws {
        let sentence = "use ft_scroll_to (it searches by scrolling)"
        let scrollable = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), scrollable: true),
        ])

        let snapshotSideDriver = FakeDriver()
        snapshotSideDriver.snapshotResponse = scrollable
        let snapshotSideServer = MCPServer(write: { _ in }, makeDriver: { _ in snapshotSideDriver },
                                           recordSnapshot: { _, _, _ in })
        let snapshotSideBody = text(try await snapshotSideServer.call(
            tool: "ft_snapshot", args: ["waitFor": "*週間天気*", "timeout": 0.0]))

        let tapSideDriver = FakeDriver()
        tapSideDriver.snapshotResponse = scrollable
        let tapSideServer = MCPServer(write: { _ in }, makeDriver: { _ in tapSideDriver },
                                      recordSnapshot: { _, _, _ in })
        tapSideServer.settleWaitSeconds = 0
        let tapSideBody = text(try await tapSideServer.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "*週間天気*", "timeout": 0.0]))

        XCTAssertTrue(snapshotSideBody.contains(sentence), snapshotSideBody)
        XCTAssertTrue(tapSideBody.contains(sentence), tapSideBody)
    }

    // MARK: - ② waitFor: 操作が効いていない可能性(snapshotAfter 経由だけ)

    /// **本丸**: 操作前と操作後の木が指紋まで一致するときだけ「効いていないかもしれない」を足す
    /// (実測: tenki.jp の「2週間」タブは ok を返したのに画面が遷移しなかった)
    func testWaitForTimeoutMentionsNoEffectWhenTreeIsIdenticalToBeforeAction() async throws {
        let driver = FakeDriver()
        let unchanged = snapshot([
            element(1, type: "button", id: "tab_2weeks", label: "2週間",
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40)),
        ])
        driver.snapshotResponse = unchanged
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        // 1回目の ft_snapshot が lastSnapshots(= beforeAction)を確立する。driver の木は
        // 差し替えないので、tap 後の freshSnapshot も同一内容(同一 identity → 同一 base)を返す
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let body = text(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "*週間予報*", "timeout": 0.0]))
        XCTAssertTrue(body.contains("the action itself may not have taken effect"), body)
    }

    /// **陰性**: 操作後に木が変わっていれば(=何かは起きた)、この文は出さない
    /// (既存挙動を壊していないことの回帰ガード)
    func testWaitForTimeoutStaysSilentWhenTreeChangedAfterAction() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snapshot([
            element(1, type: "button", id: "tab_2weeks", label: "2週間",
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40)),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // tap の後に木を差し替える(遷移が起きた形)
        driver.snapshotResponse = snapshot([
            element(1, type: "staticText", id: "page_title", label: "2週間天気",
                    frame: FTRect(x: 0, y: 0, width: 200, height: 40)),
        ])
        let body = text(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "*週間予報*", "timeout": 0.0]))
        XCTAssertFalse(body.contains("the action itself may not have taken effect"), body)
    }

    // MARK: - ③ ft_scroll_to: 多重ヒットを黙らない

    /// **本丸**: 同じ部分一致セレクタに3要素が当たるなら、件数と「先頭が使われた」ことを言う
    /// (実測: tenki.jp で "*週間*" がタブ「2週間」に当たり、週間予報の行は無視された)
    func testScrollToNamesMultipleMatches() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snapshot([
            element(1, type: "button", id: "tab_2weeks", label: "2週間",
                    frame: FTRect(x: 0, y: 40, width: 100, height: 40)),
            element(2, type: "staticText", id: "weekly_forecast_label", label: "週間天気",
                    frame: FTRect(x: 0, y: 200, width: 200, height: 40)),
            element(3, type: "staticText", label: "来週間の予定",
                    frame: FTRect(x: 0, y: 300, width: 200, height: 40)),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let body = text(try await server.call(tool: "ft_scroll_to", args: ["selector": "*週間*"]))
        XCTAssertTrue(body.contains("scrolled to"), body)
        XCTAssertTrue(body.contains("3 elements match this selector"), body)
        XCTAssertTrue(body.contains("the first in tree order was used"), body)
    }

    /// 1件しか当たらないときは何も足さない(追加コストを払わない・過剰な注記も出さない)
    func testScrollToStaysSilentWithASingleMatch() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = snapshot([
            element(1, type: "staticText", id: "weekly_forecast_label", label: "週間天気",
                    frame: FTRect(x: 0, y: 200, width: 200, height: 40)),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let body = text(try await server.call(tool: "ft_scroll_to", args: ["selector": "*週間*"]))
        XCTAssertTrue(body.contains("scrolled to"), body)
        XCTAssertFalse(body.contains("elements match this selector"), body)
    }
}
