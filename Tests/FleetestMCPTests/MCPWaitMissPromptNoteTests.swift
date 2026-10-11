// 待ちが外れたとき、前面に新しく出たもの(alert・ボタンだけの全面シート)を名指しする(MCPServer.appearedPromptNote)。
// 操作の応答では曖昧ラベル・重複 id の表の明細を畳み、ft_snapshot だけ満額にする(MCPServer.briefKeys)

import XCTest
import FTCore
import FTTestSupport
@testable import fleetest_mcp

final class MCPWaitMissPromptNoteTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ label: String?, id: String? = nil, depth: Int = 1,
                    y: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 20, y: y, width: 300, height: 44), depth: depth)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    func testANewSheetWithOnlyNewButtonsIsNamedAndAnOrdinaryScreenIsNot() {
        let before = tree([el(1, "button", "経路"), el(2, "button", "共有"), el(3, "button", "閉じる"),
                           el(4, "staticText", "立川駅")])
        // 実測の全面シート: 押せるのは「通知を有効にする / 今はしない」だけ
        let sheet = tree([el(10, "staticText", "友達が到着予定時刻を共有するときに通知を受信"),
                          el(11, "button", "通知を有効にする", y: 722), el(12, "button", "今はしない", y: 784)])
        let note = MCPServer.appearedPromptNote(before: before, now: sheet)
        XCTAssertTrue(note.contains("offers only \"通知を有効にする\" / \"今はしない\""), note)
        // **1つが前の画面にもあるボタンでも言う**(実測: 販促シートの「閉じる」は経路画面にもあり、黙った)
        let sheet2 = tree([el(10, "staticText", "友達が到着予定時刻を共有するときに通知を受信"),
                           el(11, "button", "通知を有効にする", y: 722), el(12, "button", "閉じる", y: 784)])
        XCTAssertTrue(MCPServer.appearedPromptNote(before: before, now: sheet2).contains("offers only"))
        // 押せる物が減っていない(= 同じ規模の別画面)なら言わない
        let bigger = tree([el(20, "button", "A"), el(21, "button", "B"), el(22, "button", "C"), el(23, "button", "D")])
        XCTAssertEqual(MCPServer.appearedPromptNote(before: bigger, now: tree([el(30, "button", "X"), el(31, "button", "Y"), el(32, "button", "Z"), el(33, "button", "W")])), "")
        // 押せる物が前回もあった(= 同じ画面の続き)なら言わない
        XCTAssertEqual(MCPServer.appearedPromptNote(before: before, now: tree([el(1, "button", "経路")])), "")
        // 比べる木が無ければ言わない
        XCTAssertEqual(MCPServer.appearedPromptNote(before: nil, now: sheet), "")
    }

    func testANewAlertIsNamedWithItsButtons() {
        let before = tree([el(1, "button", "経路")])
        let now = tree([el(1, "button", "経路"), el(2, "alert", "安全に目的地に到達するために"),
                        el(3, "button", "OK", depth: 2)])
        let note = MCPServer.appearedPromptNote(before: before, now: now)
        XCTAssertTrue(note.contains("安全に目的地に到達するために"), note)
        XCTAssertTrue(note.contains("buttons: \"OK\""), note)
        XCTAssertFalse(note.contains("alert alert"), "型名と語が重なった: \(note)")
    }

    /// **先頭・末尾の空白を持つラベルはそう言う**(Google マップの `"  埼京線"`)。無ければ言わない
    func testLabelsWithLeadingSpacesAreCalledOut() {
        let spaced = tree([el(1, "button", "  埼京線", y: 100), el(2, "button", "  埼京線", y: 300)])
        XCTAssertTrue(MCPServer.ambiguousLabelsNote(spaced).contains("really has them"))
        let plain = tree([el(1, "button", "埼京線", y: 100), el(2, "button", "埼京線", y: 300)])
        XCTAssertFalse(MCPServer.ambiguousLabelsNote(plain).contains("really has them"))
    }

    /// 畳んだ群の行の同じ理由は1回だけ末尾に言う(5群が同じ文を5回繰り返していた)。1群だけ・理由が違う行はそのまま
    func testASharedTrailingReasonIsSaidOnce() {
        let reason = "repeats inside #list; every alternative is index-based, so tap by ref instead."
        let lines = ["note: header", "  #a ×2: [1] [2] — \(reason)", "  #b ×3: [3] [4] [5] — \(reason)",
                     "  #c ×2: [6] [7] — none of these have a selector on this screen; tap by ref instead."]
        let folded = MCPServer.foldingSharedReasons(lines)
        XCTAssertEqual(folded, ["note: header", "  #a ×2: [1] [2]", "  #b ×3: [3] [4] [5]",
                                "  #c ×2: [6] [7] — none of these have a selector on this screen; tap by ref instead.",
                                "  (lines above with no trailing note: \(reason))"])
        XCTAssertEqual(MCPServer.foldingSharedReasons(Array(lines.prefix(2))), Array(lines.prefix(2)))
    }

    /// `once` の鍵はデバイスごと(1つのサーバを2つのエージェントが別のデバイスで共有すると、2人目が初出を見ていないのに
    /// 「初出の注記を見よ」と言われた)
    func testOnceIsCountedPerDevice() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        server.noteScope = "ios:8137"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F")
        server.noteScope = "android:emulator-5562"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F", "別のデバイスなのに短縮された")
        server.noteScope = "ios:8137"
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "S")
    }

    /// **ft_launch でそのデバイスの `once` の鍵を忘れる**(前の呼び手が初出を見ていると、次の呼び手が最初から短縮形を受け取った)
    func testLaunchResetsTheOnceNotesOfThatDevice() async throws {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let scope = server.noteScope
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F")
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "S")
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        XCTAssertEqual(server.noteScope, scope, "同じデバイスの鍵を見ていない")
        XCTAssertEqual(server.once("k", full: "F", short: "S"), "F", "ft_launch の後も短縮形のまま")
    }

    /// **ft_scroll_to の応答では残像の対処文に「先に ft_scroll_to で出せ」と言わない**(探索の結果に対して循環する)。
    /// 配線は実アプリの木(容器の上端より上へ送られた行が画面内に残る `ios-maps_transit_boarding_cards`)で ft_scroll_to を通して確かめる
    func testLeftoverRemedyAfterAScrollSearchDoesNotSuggestScrollingFirst() async throws {
        XCTAssertFalse(MCPServer.leftoverRemedy(afterScrollSearch: true).contains("ft_scroll_to"))
        XCTAssertTrue(MCPServer.leftoverRemedy(afterScrollSearch: false).contains("ft_scroll_to first"))
        let corpus = try RealAppSnapshotCorpus.all()
        let fixture = try XCTUnwrap(corpus.first { $0.name == "ios-maps_transit_boarding_cards" }).snapshot
        let driver = FakeDriver()
        driver.snapshotResponse = fixture
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let text = try await server.call(tool: "ft_scroll_to", args: ["selector": "#TransitNavigationEndButton"])
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("scroll-leftover"), "残像の注記が出る木を選べていない: \(text.prefix(300))")
        XCTAssertTrue(text.contains("rows the search scrolled past"), text)
        XCTAssertFalse(text.contains("ft_scroll_to first"), text)
    }

    /// **表の定型フッター(「Tap these by ref…」)は初出だけ**(ref で打つ探索中は毎回読まない)
    func testTheTableFooterIsOnlyInTheFirstNote() {
        // 同じラベルで id が一意 = 群は畳めず(安定なセレクタがある)、brief では明細を畳んでフッターが付く形
        let snapshot = tree([el(2, "button", "項目", id: "item_a", y: 100), el(3, "button", "項目", id: "item_b", y: 200),
                             el(4, "button", "行", id: "row_a", y: 300), el(5, "button", "行", id: "row_b", y: 400)])
        let first = MCPServer.ambiguousLabelsNote(snapshot, abbreviated: false, brief: true)
        XCTAssertTrue(first.contains("Tap these by ref"), first)
        let later = MCPServer.ambiguousLabelsNote(snapshot, abbreviated: true, brief: true)
        XCTAssertTrue(later.contains("\"項目\" ×2"), later)
        XCTAssertFalse(later.contains("Tap these by ref"), later)
    }

    /// **金額の表記が待った語と違うときに言う**(`*円*` で待ったのに画面は `¥715`)。同じ表記・金額の無い画面では黙る
    func testCurrencyNotationIsNamedWhenTheWaitUsedAnotherMark() {
        let yen = tree([el(1, "staticText", "2, 番線, ¥715 IC料金"), el(2, "button", "経路")])
        let hint = MCPServer.currencyNotationHint("*円*", in: yen)
        XCTAssertTrue(hint.contains("written with \"¥\", not \"円\""), hint)
        XCTAssertTrue(hint.contains("*¥*"), hint)
        XCTAssertEqual(MCPServer.currencyNotationHint("*¥*", in: yen), "", "同じ表記で外れたのなら表記の話ではない")
        XCTAssertEqual(MCPServer.currencyNotationHint("*円*", in: tree([el(1, "staticText", "¥マーク"), el(2, "button", "経路")])), "",
                       "数字の無いラベルは金額ではない")
        XCTAssertEqual(MCPServer.currencyNotationHint("*経路*", in: yen), "")
    }

    /// **scrollFrame の注記は、探索の後の木にその容器があれば後の木で作る**(前の木は `snapshotAfter: false` の後は古い画面の
    /// ことがあり、今ある容器を「無い」と言った)。後の木に無ければ前の木(探索がシートを畳んで容器が消えた形)
    func testScrollFrameHintUsesTheCurrentTreeWhenTheFrameIsThere() {
        let stale = tree([el(1, "scrollView", nil, id: "TransitDirectionsListView")])
        let current = tree([el(5, "scrollView", nil, id: "RoutePlanningOverviewViewController")])
        let args: [String: Any] = ["scrollFrame": "#RoutePlanningOverviewViewController"]
        XCTAssertEqual(MCPServer.scrollFrameHintTree(args, before: stale, after: current).elements.first?.ref, 5)
        let gone = tree([el(9, "button", "閉じる")])
        XCTAssertEqual(MCPServer.scrollFrameHintTree(args, before: current, after: gone).elements.first?.ref, 5)
    }

    /// **同じ画面のスクロール領域の注記は繰り返さない**。画面が変わって文が変われば言う
    func testTheScrollAreaNoteIsNotRepeatedForTheSameScreen() async throws {
        func scroller(_ ref: Int, _ id: String, y: Double) -> ElementInfo {
            var e = el(ref, "scrollView", nil, id: id, y: y); e.scrollable = true
            e.frame = FTRect(x: 0, y: y, width: 402, height: 300); return e
        }
        let screenA = tree([scroller(1, "list_a", y: 100), el(2, "button", "A1", depth: 2, y: 120),
                            scroller(3, "list_b", y: 450), el(4, "button", "B1", depth: 2, y: 470)])
        let driver = FakeDriver()
        driver.snapshotResponse = screenA
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        func text() async throws -> String {
            try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
        }
        let first = try await text()
        XCTAssertTrue(first.contains("scroll areas on screen"), first)
        let second = try await text()
        XCTAssertFalse(second.contains("scroll areas on screen"), second)
        driver.snapshotResponse = tree([scroller(1, "list_c", y: 100), el(2, "button", "C1", depth: 2, y: 120),
                                        scroller(3, "list_d", y: 450), el(4, "button", "D1", depth: 2, y: 470)])
        let changed = try await text()
        XCTAssertTrue(changed.contains("scroll areas on screen"), changed)
    }

    /// **「take a fresh ft_snapshot」の促しはデバイスごとに初回だけ**(木を返さない操作のたびに付いていた)
    func testTheTakeAFreshSnapshotHintIsGivenOnce() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "保存", id: "save_btn")])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let first = try await server.call(tool: "ft_tap", args: ["ref": 1]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(first.contains("take a fresh ft_snapshot"), first)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let second = try await server.call(tool: "ft_tap", args: ["ref": 1]).compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(second.contains("take a fresh ft_snapshot"), second)
    }

    /// **畳んだ群の注記は初出だけ**(2回目以降は木の畳み行が同じ事実を言っている)
    func testTheFoldedGroupNoteIsNotRepeated() {
        var snapshot = tree([el(1, "button", "A")])
        snapshot.bulkExemptCount = 150
        XCTAssertFalse(MCPServer.bulkExemptNote(snapshot, abbreviated: false).isEmpty)
        XCTAssertEqual(MCPServer.bulkExemptNote(snapshot, abbreviated: true), "")
    }

    /// **操作の応答では、操作できる要素を含まない群(レイアウト容器だけ)を表に並べない**。ft_snapshot は満額
    func testLayoutOnlyGroupsAreLeftOutOfActionResponses() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "保存", id: "save_btn", y: 100), el(2, "button", "保存", id: "save_btn", y: 600),
                                        el(3, "other", nil, id: "TextStackView", y: 200), el(4, "other", nil, id: "TextStackView", y: 700)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let full = try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(full.contains("#TextStackView ×2"), full)
        let action = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(action.contains("#save_btn ×2"), action)
        XCTAssertFalse(action.contains("#TextStackView ×2"), "容器だけの群を操作の応答に並べた: \(action)")
    }

    /// **操作の応答では表の明細を畳み、ft_snapshot では満額**(同じ木で比べる)
    func testSelectorTablesAreFoldedInActionResponsesButNotInFtSnapshot() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "保存", id: "save_top", y: 100),
                                        el(2, "button", "保存", id: "save_bottom", y: 600)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let full = try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(full.contains("[1] #save_top"), full)
        let action = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(action.contains("\"保存\" ×2"), "事実(×N)は残す: \(action)")
        XCTAssertFalse(action.contains("[1] #save_top"), "明細を畳んでいない: \(action)")
    }

    /// **waitFor の一致は何に当たったかを名指しし、畳まれた群の中なら言う**(計測: `*円*` が畳まれた地図のピンの
    /// ラベルに当たり、運賃が出たと読み違えた)
    func testWaitForAppearedNamesTheMatchAndSaysWhenItIsFolded() {
        let pins = (0..<25).map { el(100 + $0, "other", $0 == 7 ? "ラーメン 900円" : "店 \($0)", id: "VKPointFeature",
                                     y: Double(20 * $0)) }
        let screen = tree([el(1, "button", "経路")] + pins)
        let folded = MCPServer.waitForAppearedNote("*円*", in: screen, collapsingBulk: true)
        XCTAssertTrue(folded.contains("matched [107]"), folded)
        XCTAssertTrue(folded.contains("ラーメン 900円"), folded)
        XCTAssertTrue(folded.contains("folded group #VKPointFeature"), folded)
        let expanded = MCPServer.waitForAppearedNote("*円*", in: screen, collapsingBulk: false)
        XCTAssertFalse(expanded.contains("folded"), expanded)
        let plain = MCPServer.waitForAppearedNote("経路", in: screen, collapsingBulk: true)
        XCTAssertTrue(plain.contains("matched [1]"), plain)
        XCTAssertFalse(plain.contains("folded"), plain)
    }

    /// **展開の後に容器の外で当たった一致は、そうと言う**(計測: `*立川*` がシートの見出しに当たり、リストの行に届いたと読まれた)
    func testAMatchOutsideTheScrollFrameIsNamed() {
        var step = FlowStep(action: "scrollTo")
        step.scrollFrameRect = FTRect(x: 0, y: 400, width: 402, height: 400)
        let screen = tree([el(1, "staticText", "立川駅", id: "TitleLabel", y: 100), el(2, "cell", "立川駅 5:48", y: 500)])
        let header = screen.elements[0], row = screen.elements[1]
        let outside = MCPServer.matchOutsideScrollFrameNote(header, step: step, in: screen)
        XCTAssertTrue(outside.contains("OUTSIDE the scrollFrame"), outside)
        XCTAssertEqual(MCPServer.matchOutsideScrollFrameNote(row, step: step, in: screen), "")
    }

    /// **ref が消えたのがアプリ内のアラートのせいなら、アラートを名指しする**(「画面が変わった」と言わない)
    func testAGoneRefBehindAnInAppAlertNamesTheAlert() {
        let target = el(5, "button", "交通機関", id: "TransitButton")
        let alertScreen = tree([ElementInfo(ref: 10, type: "alert", identifier: nil, label: "安全に目的地に到達するために",
                                            value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 40, y: 300, width: 320, height: 200), depth: 1),
                                el(11, "button", "OK", depth: 2, y: 440)])
        let message = RefGuard.goneMessage(ref: 5, target: target,
                                           inAppAlert: MCPServer.frontInAppAlertWithButtons(alertScreen))
        XCTAssertTrue(message.contains("安全に目的地に到達するために"), message)
        XCTAssertTrue(message.contains("\"OK\""), message)
        XCTAssertFalse(message.contains("the screen changed"), message)
        XCTAssertNil(MCPServer.frontInAppAlertWithButtons(tree([target])))
    }

    /// **一致の名指しはラベルを重ねず、入れ子の一致を数えない**(計測: `clickable "立川駅" "立川駅" (+23 more)`)
    func testWaitForAppearedDoesNotRepeatTheLabelOrCountNestedMatches() {
        var elements: [ElementInfo] = []
        for row in 0..<3 {
            let y = Double(100 + row * 60)
            elements.append(el(10 + row * 2, "clickable", "立川駅", y: y))
            elements.append(el(11 + row * 2, "staticText", "立川駅", depth: 2, y: y))
        }
        let note = MCPServer.waitForAppearedNote("*立川駅*", in: tree(elements), collapsingBulk: true)
        XCTAssertFalse(note.contains("\"立川駅\" \"立川駅\""), note)
        XCTAssertTrue(note.contains("(+2 more)"), note)
    }

    /// **重複 id の表は操作の応答で同じなら繰り返さない。ft_snapshot では毎回出す**
    func testDuplicateTablesAreNotRepeatedInActionResponses() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = tree([el(1, "button", "経路", id: "StepsLabel", y: 100),
                                        el(2, "button", "経路", id: "StepsLabel", y: 300),
                                        el(3, "button", "経路", id: "StepsLabel", y: 500)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        func text(_ tool: String, _ args: [String: Any]) async throws -> String {
            try await server.call(tool: tool, args: args).compactMap { $0["text"] as? String }.joined()
        }
        let first = try await text("ft_tap", ["ref": 1, "snapshotAfter": true])
        XCTAssertTrue(first.contains("#StepsLabel"), first)
        let second = try await text("ft_tap", ["ref": 1, "snapshotAfter": true])
        XCTAssertFalse(second.contains("duplicate"), second)
        let snapshot = try await text("ft_snapshot", [:])
        XCTAssertTrue(snapshot.contains("duplicate"), snapshot)
    }
}
