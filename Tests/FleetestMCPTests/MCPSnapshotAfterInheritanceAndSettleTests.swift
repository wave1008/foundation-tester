// snapshotAfter の2改善(2026-08-10)。どちらも実アプリ監査(Apple マップ)が動機:
// - interactiveOnly/expandBulk を毎回付け直す手間(フィルタは付けたり外したりしない使い方が大半)
// - push 遷移直後の snapshotAfter が操作前と同じ木を返し、別途 ft_snapshot が要ることがあった

import XCTest
import FTCore
@testable import fleetest_mcp

private func settleElement(ref: Int, type: String = "Button", id: String? = nil,
                           label: String? = nil, value: String? = nil,
                           x: Double = 10, y: Double = 20,
                           w: Double = 100, h: Double = 40) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
               placeholder: nil, enabled: true,
               frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
}

private func settleSnapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: 0)
}

private func bodyText(_ content: [[String: Any]]) -> String {
    content.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

// MARK: - interactiveOnly/expandBulk の継承

final class MCPSnapshotAfterFilterInheritanceTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        driver.snapshotResponse = settleSnapshot([
            settleElement(ref: 1, id: "login_btn", label: "ログイン"),
            // ラベル・値の無い other = interactiveOnly が隠す「レイアウト専用行」
            settleElement(ref: 2, type: "other", id: "spacer", x: 0, y: 70, w: 390, h: 20),
        ])
    }

    /// ft_snapshot で明示した interactiveOnly: true が、続く snapshotAfter 付き ft_tap へ継承される
    func testInteractiveOnlyIsInheritedIntoSnapshotAfter() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let after = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertFalse(after.contains("id=spacer"), after)
        XCTAssertTrue(
            after.contains("interactiveOnly: true inherited from an earlier call"), after)
    }

    /// **継承の宣言は1回だけ**(毎回の応答に同じ1行が載っていた = 計測で指摘)。同じ値を明示し直しても言い直さない
    /// (毎回明示する読み手に毎回出ていた = 計測で4回)。値を変えたら、次の継承でまた1回言う
    func testTheInheritanceIsAnnouncedOnlyOnceUntilTheValueChanges() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
        let second = bodyText(try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertFalse(second.contains("id=spacer"), "継承そのものは続く: \(second)")
        XCTAssertFalse(second.contains("inherited from an earlier call"), second)
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "interactiveOnly": true])
        let sameValue = bodyText(try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertFalse(sameValue.contains("inherited from an earlier call"), sameValue)
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "interactiveOnly": false])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "interactiveOnly": true])
        let changed = bodyText(try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertTrue(changed.contains("inherited from an earlier call"), changed)
    }

    /// **ft_batch の最後の木も継承する**(ft_batch だけ全行の木を返していた = 計測で指摘)
    func testTheBatchTreeInheritsInteractiveOnly() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let text = bodyText(try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn'"]))
        XCTAssertTrue(text.contains("All 1 step(s) passed"), text)
        XCTAssertFalse(text.contains("id=spacer"), text)
    }

    /// 呼び出し側が明示した値が常に優先 —— interactiveOnly: false を渡せば継承されない
    func testExplicitFalseOverridesInheritance() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let after = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "interactiveOnly": false]))
        XCTAssertTrue(after.contains("id=spacer"), after)
        XCTAssertFalse(after.contains("inherited from an earlier call"), after)
    }

    /// **ft_launch(snapshotAfter 付き)に明示した指定も覚える**。ft_snapshot の指定しか覚えていなかったので、
    /// 起動の次の ft_tap が全行の木を返していた(計測のエージェント3人が同じ指摘)
    func testAnExplicitFilterOnAnyTreeReturningToolIsRemembered() async throws {
        _ = try await server.call(tool: "ft_launch",
                                  args: ["bundleId": "com.example.app", "snapshotAfter": true, "interactiveOnly": true])
        let after = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertFalse(after.contains("id=spacer"), after)
        XCTAssertTrue(after.contains("interactiveOnly: true inherited from an earlier call"), after)
    }

    /// **素の ft_snapshot も継承する**(「以後は黙って引き継ぐ」と宣言した後に、素の ft_snapshot が全行の木を返して
    /// 宣言が嘘になっていた = 計測で指摘)。外すのは false の明示だけ
    func testAPlainFtSnapshotInheritsAndOnlyAnExplicitFalseClears() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": true])
        let plain = bodyText(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertFalse(plain.contains("id=spacer"), plain)
        _ = try await server.call(tool: "ft_snapshot", args: ["interactiveOnly": false])
        let after = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertTrue(after.contains("id=spacer"), after)
        XCTAssertFalse(after.contains("inherited from an earlier call"), after)
    }
}

// MARK: - settle-lite(操作前と見分けが付かない木は1回だけ再読する。2026-08-10)

final class MCPSnapshotAfterSettleLiteTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func snapshotCalls(from index: Int) -> Int {
        driver.calls[index...].filter { $0 == "snapshot" }.count
    }

    /// 操作前後で同一の木 → 1回だけ撮り直す(driver.calls に snapshot が2回入る)。
    /// 撮り直しても変わらなければ「変わっていないかもしれない」と言うだけでそれ以上は待たない
    func testUnchangedTreeIsReReadOnceAndNotesItMightNotHaveChanged() async throws {
        let same = settleSnapshot([settleElement(ref: 1, id: "login_btn", label: "ログイン")])
        driver.scriptedSnapshots = [same, same, same]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let callsBefore = driver.calls.count
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertEqual(snapshotCalls(from: callsBefore), 2, "\(driver.calls)")
        XCTAssertTrue(text.contains("still looked unchanged"), text)
    }

    /// 撮り直したら実際に木が変わっていた(push 遷移を模す)→ 撮り直した木を返し、その旨の note を出す
    func testChangedOnReReadRendersTheNewTreeAndNotesTheReRead() async throws {
        let before = settleSnapshot([settleElement(ref: 1, id: "login_btn", label: "ログイン")])
        let after = settleSnapshot([
            settleElement(ref: 1, id: "login_btn", label: "ログイン"),
            settleElement(ref: 2, type: "staticText", id: "welcome", label: "ようこそ"),
        ])
        driver.scriptedSnapshots = [before, before, after]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("tree below is the re-read"), text)
        XCTAssertTrue(text.contains("id=welcome"), text)
    }

    /// **何も読めない木(全要素がレイアウト専用 = 遷移の途中)は1回だけ読み直し、そう言う**
    /// (実測: Apple マップで全画面シートを閉じた直後の木が layout-only の1行だけで、黙って返していた)
    func testABlankTreeRightAfterTheActionIsReReadOnce() async throws {
        let before = settleSnapshot([settleElement(ref: 1, id: "dismiss", label: "今はしない")])
        let blank = settleSnapshot([settleElement(ref: 1, type: "other")])
        let after = settleSnapshot([settleElement(ref: 1, type: "searchField", id: "MapsSearchTextField", label: "検索")])
        driver.scriptedSnapshots = [before, blank, after]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("had nothing readable on it"), text)
        XCTAssertTrue(text.contains("id=MapsSearchTextField"), text)
    }

    /// **waitForChange・撮り直しの後の木に「操作の直後に読んだ」と言わない**(計測で指摘)。待たずに読んだ回だけ言う
    func testTheImmediateReadNoteIsNotAddedAfterAWait() async throws {
        let before = settleSnapshot([settleElement(ref: 1, id: "login_btn", label: "ログイン")])
        let after = settleSnapshot([settleElement(ref: 1, id: "login_btn", label: "ログイン"),
                                    settleElement(ref: 2, type: "staticText", id: "welcome", label: "ようこそ")])
        driver.scriptedSnapshots = [before, before, after, after]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let changed = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true, "waitForChange": true]))
        XCTAssertFalse(changed.contains("immediate"), changed)
        // 対照: 待たずに読んで木が変わっていた回(撮り直しも入らない)には言う
        driver.scriptedSnapshots = [before, before]
        let immediate = bodyText(try await server.call(tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(immediate.contains("read immediately after the action") || immediate.contains("immediate read"), immediate)
    }

    /// value だけ変わっている(ft_type 直後の典型)→ 再読しない(snapshot は1回だけ)。
    /// value を比較に含めるのが要点 —— 含めなければこのケースも「変化なし」と誤認して待たされる
    func testValueOnlyChangeSkipsTheReRead() async throws {
        let before = settleSnapshot([settleElement(ref: 1, type: "textField", id: "search_field")])
        let after = settleSnapshot(
            [settleElement(ref: 1, type: "textField", id: "search_field", value: "東京タワー")])
        driver.scriptedSnapshots = [before, after]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let callsBefore = driver.calls.count
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertEqual(snapshotCalls(from: callsBefore), 1, "\(driver.calls)")
        XCTAssertFalse(text.contains("still looked unchanged"), text)
        XCTAssertFalse(text.contains("tree below is the re-read"), text)
    }

    /// 操作前の木を知らない(lastSnapshots が無い)ときは何もしない —— 判断材料が無いので待たない。
    /// **座標の範囲判定の生読み(tap の前の1枚・§19 M4)は世代を作らない**ので、それを基準に
    /// 待つこともない(snapshot は範囲判定の1枚 + snapshotAfter の1枚 = 2)
    func testNoPriorSnapshotSkipsSettleLiteEntirely() async throws {
        driver.snapshotResponse = settleSnapshot([settleElement(ref: 1, id: "login_btn")])
        let callsBefore = driver.calls.count
        let text = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertEqual(snapshotCalls(from: callsBefore), 2, "\(driver.calls)")
        XCTAssertFalse(text.contains("still looked unchanged"), text)
        XCTAssertFalse(text.contains("tree below is the re-read"), text)
    }
}

// MARK: - ft_type(ref なし)の typedIntoNote が settle-lite の基準を汚さない
//
// typedIntoNote は「どこへ入ったか」を確かめるため、type アクションの**後**に木を読む。
// この読みを adoptSnapshot(lastSnapshots を更新する経路)に通すと、続く snapshotAfterBody の
// `beforeAction` が「操作前」ではなく「操作後」になり、実際は候補一覧が増えて画面が変わって
// いるのに「変化なし」と誤報する。生読み(adoptSnapshot を通さない)に直したことを確認する

final class MCPTypeSettleLiteInheritanceTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        driver.supportsCacheBypass = true
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    /// 入力で候補一覧が実際に増えたのに「still looked unchanged」が出ない(実害の再現)。
    /// **中間読みと snapshotAfterBody の読みは同じ木にする**(実害の形): 候補は typedIntoNote の
    /// 読みの時点で既に出ている。汚染すると beforeAction がこの木になり「変化なし」と誤報する —
    /// 別々の木にすると汚染しても counts が違って settle 分岐に入らず、変異を素通しする
    func testTypeThatVisiblyChangesTheTreeDoesNotFalselyReportUnchanged() async throws {
        let baseline = settleSnapshot([
            settleElement(ref: 1, type: "textField", id: "search_field"),
        ])
        var focusedAfterType = settleElement(ref: 1, type: "textField", id: "search_field",
                                             value: "query")
        focusedAfterType.focused = true
        let candidateRow = settleElement(ref: 2, type: "staticText", id: "candidate_row",
                                         label: "Query suggestion 1", x: 10, y: 70)
        let afterWithCandidates = settleSnapshot([focusedAfterType, candidateRow])
        driver.scriptedSnapshots = [baseline, afterWithCandidates, afterWithCandidates,
                                    afterWithCandidates]

        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = bodyText(try await server.call(
            tool: "ft_type", args: ["text": "query", "snapshotAfter": true]))

        XCTAssertTrue(text.contains("into #search_field"), text)
        XCTAssertFalse(text.contains("still looked unchanged"), text)
        XCTAssertFalse(text.contains("tree below is the re-read"), text)
        XCTAssertTrue(text.contains("id=candidate_row"), text)
    }
}
