// 往復を減らすために足した機能(2026-08-09 のマップ探索セッションの実測が動機)。
//
// 1セッション 46 呼び出しのうち 21 回が「直前の操作の結果を見るためだけの ft_snapshot」で、
// ほかに「system アプリが引けず Bash へ落ちた」「半開シートを人手で広げて撃ち直した」
// 「所要時間を測るのに date をシェルで撃った」が各1回ずつあった。
// ここが未検証だと、どれも**黙って効かなくなる**(応答が少し短くなるだけで赤にならない)。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPRoundTripTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - snapshotAfter(操作の結果をその場で返す)

    func testTapWithSnapshotAfterAppendsTheTree() async throws {
        let text = bodyText(try await server.call(tool: "ft_tap",
                                                  args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("tap [1] done"), text)
        XCTAssertTrue(text.contains("screen: 390x844"), text)
        XCTAssertTrue(text.contains("id=login_btn"), text)
    }

    /// **撮り直しを勧めない**: 木を返しておいて「ft_snapshot を撮れ」と言うと、
    /// 往復を減らすために足した機能が往復を増やす助言と矛盾する
    func testSnapshotAfterSuppressesTheTakeAFreshSnapshotAdvice() async throws {
        let without = bodyText(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(without.contains("take a fresh ft_snapshot"), without)
        let with = bodyText(try await server.call(tool: "ft_tap",
                                                  args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertFalse(with.contains("take a fresh ft_snapshot"), with)
    }

    func testTypeAndDragAlsoHonourSnapshotAfter() async throws {
        let typed = bodyText(try await server.call(
            tool: "ft_type", args: ["text": "abc", "snapshotAfter": true]))
        XCTAssertTrue(typed.contains("screen: 390x844"), typed)
        let dragged = bodyText(try await server.call(
            tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0, "dy": -100.0,
                                    "snapshotAfter": true]))
        XCTAssertTrue(dragged.contains("screen: 390x844"), dragged)
    }

    /// 既定では木を足さない(全呼び出しに一覧が付くとトークンを常時払うことになる)
    func testTapWithoutSnapshotAfterStaysShort() async throws {
        let text = bodyText(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("screen: 390x844"), text)
    }

    /// **木が読めなくても操作の結果は返す**: throw すると「タップは効いたのにエラー」になり、
    /// 読み手が操作を撃ち直して二重操作になる
    func testSnapshotAfterFailureDoesNotHideASuccessfulAction() async throws {
        let text = bodyText(try await server.call(tool: "ft_tap",
                                                  args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(text.contains("tap (1.0, 2.0) done"), text)
        driver.failing = ["snapshot"]
        let failed = bodyText(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true]))
        XCTAssertTrue(failed.contains("tap (1.0, 2.0) done"), failed)
        XCTAssertTrue(failed.contains("snapshotAfter could not read the screen"), failed)
    }

    // MARK: - snapshotAfter は interactiveOnly/expandBulk も透過する(2026-08-10)
    //
    // `snapshotAfterBody` は元から `snapshotBody(args:)` を経由しており、`args["interactiveOnly"]`/
    // `args["expandBulk"]` はそこで読まれていた —— **機能はすでに透過していた**。欠けていたのは
    // ft_tap/ft_type/ft_drag のツールスキーマ宣言だけ(MCP クライアントは宣言されていない引数を
    // 送る術が無い)。ここでは実際に折りたたみ・展開が効くことを確かめる

    func testTapSnapshotAfterHonoursInteractiveOnly() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "Button", identifier: "login_btn", label: "ログイン",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1),
                // ラベル・値の無い other = interactiveOnly が隠す「レイアウト専用行」
                ElementInfo(ref: 2, type: "other", identifier: "spacer", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 70, width: 390, height: 20), depth: 1),
            ],
            truncatedCount: 0)
        let full = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true]))
        XCTAssertTrue(full.contains("id=spacer"), full)
        let filtered = bodyText(try await server.call(
            tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "interactiveOnly": true]))
        XCTAssertFalse(filtered.contains("id=spacer"), filtered)
        XCTAssertTrue(filtered.contains("interactiveOnly: 1 layout-only line(s) hidden"), filtered)
    }

    /// expandBulk も同様に効くこと(20+ 同一 id の非対話葉が個別列挙に戻る)
    func testDragSnapshotAfterHonoursExpandBulk() async throws {
        let pins = (1...25).map { i in
            ElementInfo(ref: i, type: "other", identifier: "poi", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(i), y: 100, width: 4, height: 4), depth: 1)
        }
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: pins, truncatedCount: 0)
        let folded = bodyText(try await server.call(
            tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0, "dy": -100.0, "snapshotAfter": true]))
        XCTAssertTrue(folded.contains("id=poi ×25 collapsed"), folded)
        let expanded = bodyText(try await server.call(
            tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0, "dy": -100.0,
                                    "snapshotAfter": true, "expandBulk": true]))
        XCTAssertFalse(expanded.contains("×25 collapsed"), expanded)
        XCTAssertEqual(expanded.components(separatedBy: "id=poi").count - 1, 25, expanded)
    }

    // MARK: - 撃った値・撃った手が draft に残る(2026-08-10 レビュー: 3秒の長押しが
    // 1秒に化ける / doubleTap・pinch が下書きから消える、の両方を塞ぐ)

    func testPressHoldSecondsReachesTheDraft() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])  // ref の台帳を作る(実フローと同順)
        _ = try await server.call(tool: "ft_press", args: ["ref": 1, "holdSeconds": 3.0])
        let draft = bodyText(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("holdSeconds: 3"), draft)
    }

    func testDoubleTapAndPinchAreRecordedForTheDraft() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_double_tap", args: ["ref": 1])
        _ = try await server.call(tool: "ft_pinch", args: ["ref": 1, "scale": 3.0])
        let draft = bodyText(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("doubleTap(\"#login_btn\")"), draft)
        XCTAssertTrue(draft.contains("pinchOut(\"#login_btn\", scale: 3)"), draft)
    }

    /// drag は DSL に対応コマンドが無いが、探索の再現性のため TODO 行として下書きに残る
    func testDragIsRecordedAsATodoLine() async throws {
        _ = try await server.call(tool: "ft_drag",
                                  args: ["fromX": 10.0, "fromY": 20.0, "dy": -100.0])
        let draft = bodyText(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("drag at (10.0, 20.0)"), draft)
    }

    /// ft_drag もスキーマに waitFor を持つ以上、snapshotAfter 無しで渡されたら
    /// 「待たなかった」と言う(他の操作系と同じ note。黙って落とすと待ったつもりで読まれる)
    func testDragWaitForWithoutSnapshotAfterSaysItWasIgnored() async throws {
        let text = bodyText(try await server.call(
            tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0, "dy": -100.0,
                                    "waitFor": "#sheet_title"]))
        XCTAssertTrue(text.contains("waitFor requires snapshotAfter: true"), text)
    }

    // MARK: - elapsedMs(所要時間を毎回返す)

    func testEveryCallReportsItsElapsedTime() async throws {
        let content = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let last = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertTrue(last.hasPrefix("⏱ "), last)
    }

    /// **本文とは別のブロックにする**: 読み手は content[0] を本文として読むので、
    /// 混ぜると所要時間が結果の文字列の一部になる
    func testElapsedIsASeparateContentBlock() async throws {
        let content = try await server.call(tool: "ft_tap", args: ["ref": 1])
        XCTAssertEqual(content.count, 2)
        let body = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(body.contains("⏱"), body)
    }

    func testElapsedTextSwitchesUnitAtOneSecond() {
        XCTAssertEqual(MCPServer.elapsedText(milliseconds: 0), "0ms")
        XCTAssertEqual(MCPServer.elapsedText(milliseconds: 999), "999ms")
        XCTAssertEqual(MCPServer.elapsedText(milliseconds: 1000), "1.0s")
        XCTAssertEqual(MCPServer.elapsedText(milliseconds: 12_340), "12.3s")
    }

    // MARK: - 半開シートのグラバー特定(ft_scroll_to の自動展開)

    private func snapshot(_ elements: [ElementInfo],
                          height: Double = 874) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: height),
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, id: String?, label: String? = nil,
                         y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 150, y: y, width: 100, height: 24), depth: 1)
    }

    func testSheetGrabberIsFoundByName() {
        let snap = snapshot([element(1, id: "Card grabber", y: 640),
                             element(2, id: "list", y: 700)])
        XCTAssertEqual(MCPServer.sheetGrabber(in: snap)?.ref, 1)
    }

    /// **名前で特定できないなら何もしない**: 当てずっぽうのドラッグは地図やリストを勝手に動かす
    func testNoGrabberMeansNoAutomaticDrag() {
        let snap = snapshot([element(1, id: "header", y: 640), element(2, id: "list", y: 700)])
        XCTAssertNil(MCPServer.sheetGrabber(in: snap))
    }

    /// 既に上まで開いているグラバーは対象外(更に引いても広がらず、閉じる実装がある)
    func testGrabberNearTheTopIsLeftAlone() {
        let snap = snapshot([element(1, id: "Card grabber", y: 60)])
        XCTAssertNil(MCPServer.sheetGrabber(in: snap))
    }


    // MARK: - 枠を食っている id 群の名指し(打ち切り注記)

    func testTruncationNoteNamesTheGroupEatingTheCap() {
        var elements = (1...30).map { element($0, id: "VKPointFeature", label: "POI", y: 100) }
        elements.append(element(31, id: "row", y: 200))
        let snap = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: elements, truncatedCount: 13)
        let note = MCPServer.truncationNote(snap)
        XCTAssertTrue(note.contains("13 element(s) were dropped"), note)
        XCTAssertTrue(note.contains("#VKPointFeature alone accounts for 30"), note)
    }

    /// 打ち切っていないなら黙る(毎回出る注記は読まれなくなる)
    func testNoCapHogNoteWithoutTruncation() {
        let elements = (1...30).map { element($0, id: "VKPointFeature", y: 100) }
        XCTAssertEqual(MCPServer.truncationNote(snapshot(elements)), "")
    }

    /// 小さな群は名指ししない(「30 件中 3 件が #row」は打ち手にならない)
    func testCapHogNoteIgnoresSmallGroups() {
        let elements = (1...5).map { element($0, id: "row", y: 100) }
        XCTAssertEqual(MCPServer.capHogNote(snapshot(elements)), "")
    }

    // MARK: - セレクタ引数の引用符剥がし(2026-08-12)
    //
    // DSL は Swift の文字列リテラルが引用符を剥がすが、MCP は生文字列で受ける。
    // `"*立川*"` が引用符ごと完全一致ラベルになり、スクロール探索が実在の要素へ
    // 永遠に届かなかった(実アプリで再現)。ft_batch は引用符必須なので混入は構造的に起きる

    func testQuotedSelectorArgumentsAreStripped() {
        XCTAssertEqual(MCPServer.strippedQuotes("\"*立川*\""), "*立川*")
        XCTAssertEqual(MCPServer.strippedQuotes("'#details_cardlist'"), "#details_cardlist")
        XCTAssertEqual(MCPServer.strippedQuotes("\"到着\""), "到着")
        // 剥がさない形: 引用符なし / 対でない / 中に同じ引用符(`"a"||"b"` を壊さない)
        XCTAssertEqual(MCPServer.strippedQuotes("*立川*"), "*立川*")
        XCTAssertEqual(MCPServer.strippedQuotes("\"開きっぱなし"), "\"開きっぱなし")
        XCTAssertEqual(MCPServer.strippedQuotes("\"a\"||\"b\""), "\"a\"||\"b\"")
        // `=` エスケープは先頭が引用符でないので素通り = 引用符を含むラベルの逃げ道は残る
        XCTAssertEqual(MCPServer.strippedQuotes("=\"引用ラベル\""), "=\"引用ラベル\"")
    }

    func testStrippingTouchesOnlySelectorKeys() {
        let out = MCPServer.strippingSelectorQuotes(
            ["selector": "\"到着\"", "waitFor": "'x'", "scrollFrame": 5, "text": "\"literal\""])
        XCTAssertEqual(out["selector"] as? String, "到着")
        XCTAssertEqual(out["waitFor"] as? String, "x")
        XCTAssertEqual(out["scrollFrame"] as? Int, 5)
        // type の text は入力そのもの(引用符を打ちたい利用者の意図を壊さない)
        XCTAssertEqual(out["text"] as? String, "\"literal\"")
    }

    /// **入口(call)に配線されていること**: 純粋関数が正しくても、呼ばれなければ従来どおり
    /// 引用符ごと照合されて waitFor が満了まで待つ
    func testQuotedWaitForMatchesThroughTheCallPath() async throws {
        let text = bodyText(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "\"ログイン\"", "timeout": 0.2]))
        XCTAssertFalse(text.contains("did not appear"), text)
        XCTAssertTrue(text.contains("id=login_btn"), text)
    }
}

/// CLI のフラグ表記を MCP の引数名へ言い換える(MCPMessageText)。
/// 実測(2026-08-09): ft_list_devices が「Pick one with --project」と返し、MCP には
/// そんなフラグが無かった
final class MCPMessageTextTests: XCTestCase {

    func testRewritesCLIFlagsIntoArgumentNames() {
        XCTAssertEqual(MCPMessageText.forMCP("Pick one with --project, or set defaultProject"),
                       "Pick one with project:, or set defaultProject")
    }

    /// **例示コマンドの中は触らない**: `ftester api list-scenarios project: X` は動かない
    func testLeavesShellCommandsAlone() {
        let message = "run: ftester api list-scenarios --project demo"
        XCTAssertEqual(MCPMessageText.forMCP(message), message)
    }

    /// 同じ1文に両方が居る実物の形(書き換える側と触らない側が同居する)
    func testHandlesTheRealAmbiguousProjectMessage() {
        let rewritten = MCPMessageText.forMCP(
            "multiple projects exist. Pick one with --project,"
            + " or set defaultProject via ftester machine set / LocalConfig")
        XCTAssertTrue(rewritten.contains("Pick one with project:,"), rewritten)
        XCTAssertTrue(rewritten.contains("ftester machine set"), rewritten)
    }

    /// 別のフラグの前方一致で誤爆しない(`--project-dir` は CLI 専用)
    func testDoesNotRewriteLongerFlags() {
        let message = "passes --project-dir to swift build"
        XCTAssertEqual(MCPMessageText.forMCP(message), message)
    }

    func testRewritesEveryKnownArgumentName() {
        XCTAssertEqual(MCPMessageText.forMCP("use --profile and --serial"),
                       "use profile: and serial:")
    }
}

/// C(bulk を予算外で送る)のホスト側と、F(操作列 → DSL 下書き)。
final class MCPDraftAndBulkTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - C: ホスト側の申告

    /// **「上限を超えているのは異常ではない」と言う** —— 読み手は上限値を知らないので、
    /// 120 を超える一覧を見て木が壊れていると読む余地がある
    func testBulkExemptCountIsReported() {
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [], truncatedCount: 0, bulkExemptCount: 87)
        let note = MCPServer.bulkExemptNote(snapshot)
        XCTAssertTrue(note.contains("87 element(s)"), note)
        // **「無害」と読ませない**(2026-08-10): 要素上限は守れているが、この出力の分量には
        // 効いていることまで言う
        XCTAssertTrue(note.contains("did not crowd other elements out of the tree"), note)
        XCTAssertTrue(note.contains("add to this output"), note)
    }

    /// **申告が無いブリッジ(旧版・Android)では黙る**: 嘘の安心を出さない
    func testNoBulkExemptClaimMeansNoNote() {
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [], truncatedCount: 0)
        XCTAssertEqual(MCPServer.bulkExemptNote(snapshot), "")
        // 0 を申告してきた場合も同じ(「0件を予算外にした」は言う意味が無い)
        let zero = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [], truncatedCount: 0, bulkExemptCount: 0)
        XCTAssertEqual(MCPServer.bulkExemptNote(zero), "")
    }

    // MARK: - F: 下書き生成

    func testDraftIsEmptyUntilSomethingWasDriven() async throws {
        let text = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(text.contains("No interactions recorded yet"), text)
    }

    /// 探索した手が DSL の行になり、**expectation は空の骨格**で出ること(F-5)
    func testDraftRendersTheExploredStepsWithAnEmptyExpectation() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])

        let text = body(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("@TestClass(app: \"com.example.app\""), text)
        XCTAssertTrue(text.contains("launchApp()"), text)
        XCTAssertTrue(text.contains("tap(\"#login_btn\")"), text)
        XCTAssertTrue(text.contains("type(\"#login_btn\", \"abc\")"), text)
        XCTAssertTrue(text.contains(".expectation {"), text)
        XCTAssertTrue(text.contains("TODO: assert what this scenario is supposed to prove"), text)
    }

    /// **セレクタを解決できなかった手も残す**(F-4): 消すと手順と食い違う
    func testUnresolvedStepsSurviveAsTODO() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "clickable", identifier: nil, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: nil, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 20, width: 10, height: 10), depth: 1),
            ],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        let text = body(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("TODO: no stable selector"), text)
        XCTAssertTrue(text.contains("ref 1"), text)
    }

    /// F-3: 既定は「直近の ft_launch 以降」/ all: true で全体
    func testDraftScopeDefaultsToTheLastLaunch() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.first.app"])
        _ = try await server.call(tool: "ft_swipe", args: ["direction": "up"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.second.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        let recent = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(recent.contains("com.second.app"), recent)
        XCTAssertFalse(recent.contains("swipe(.up)"), recent)

        let all = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(all.contains("swipe(.up)"), all)
    }

    /// 探索で使った ft_scroll_to は**渡した式のまま**残す(解決後の要素ではなく)
    func testScrollToKeepsTheSelectorTheCallerWrote() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_scroll_to", args: ["selector": "#login_btn"])
        let text = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(text.contains("scrollTo(\"#login_btn\""), text)
    }
}

/// G(版ズレを既定で拒否)と H(udid で指す)。
/// **ゲートそのものを通す**: 文言だけ検証すると「拒否していない」を素通しする
final class MCPVersionGateTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app",
            protocolVersion: BridgeAPI.bridgeProtocolVersion - 1)
        let fake = driver!
        // 差し替え経路でも**実際のゲートを通す**(文言だけ検証して安心しないため)
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in },
                           checksVersionOnInjectedDriver: true)
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// **全操作系が失敗する**(ft_status だけ通しても、エージェントは次のツールを呼ぶ)
    func testEveryDeviceToolRefusesOnASkewedBridge() async {
        for tool in ["ft_snapshot", "ft_tap", "ft_type", "ft_swipe", "ft_launch", "ft_screenshot"] {
            do {
                _ = try await server.call(tool: tool, args: ["ref": 1, "text": "a",
                                                            "direction": "up",
                                                            "bundleId": "com.example.app"])
                XCTFail("\(tool) が版ズレのまま通った")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("bridge protocol mismatch"),
                              "\(tool): \(error.localizedDescription)")
            }
        }
    }

    /// ft_status は「失敗するが理由と直し方を返す」(G-2)
    func testStatusFailsButExplainsHowToFixIt() async {
        do {
            _ = try await server.call(tool: "ft_status", args: [:])
            XCTFail("ft_status が版ズレのまま通った")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("bridge protocol mismatch"), text)
            XCTAssertTrue(text.contains("ftester bridge down"), text)
            XCTAssertTrue(text.contains("allowVersionSkew"), text)
        }
    }

    /// 押し通せる。ただし**毎回**警告が付く(1度言って黙らない。G-3)
    func testOverrideProceedsButWarnsEveryTime() async throws {
        for round in 1...3 {
            let text = body(try await server.call(
                tool: "ft_snapshot", args: ["allowVersionSkew": true]))
            XCTAssertTrue(text.contains("allowVersionSkew: proceeding"),
                          "\(round) 回目に警告が消えた: \(text.prefix(200))")
        }
    }

    /// 版が合っていれば素通し(ゲートが常時発火していないこと = 逆方向の変異)
    func testAMatchingBridgeIsNotBlocked() async throws {
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app",
            protocolVersion: BridgeAPI.bridgeProtocolVersion)
        let text = body(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(text.contains("screen:"), text)
        XCTAssertFalse(text.contains("mismatch"), text)
    }

    // MARK: - H: udid と port の併用

    /// 両方渡されて食い違うなら**明示的に失敗する**(黙ってどちらかを採らない)。
    /// **走査から切り離した純粋関数で見る** —— 実ブリッジ前提だと「見つからない」枝で
    /// 早期に落ちて、食い違いの判定が一度も実行されない
    func testUDIDAndPortMustAgree() throws {
        XCTAssertThrowsError(try MCPServer.reconcilePort(8123, udid: "U1", udidPorts: [8124])) {
            XCTAssertTrue($0.localizedDescription.contains("is not a bridge answering on udid"),
                          $0.localizedDescription)
        }
    }

    /// 一致していれば port を採る(食い違い判定が常時発火していないこと)
    func testUDIDAndPortAgreeing() throws {
        XCTAssertEqual(try MCPServer.reconcilePort(8123, udid: "U1", udidPorts: [8123]), 8123)
    }

    /// **同じ端末に in-app / XCUITest の2本が立っているとき、どちらの port を併記しても通る**
    /// (2026-08-12 の実アプリ監査: 先頭の1本とだけ比べていて、in-app port の併記が
    /// 「別デバイス」で誤拒否された)
    func testUDIDWithTwoBridgesAcceptsEitherPort() throws {
        XCTAssertEqual(try MCPServer.reconcilePort(8126, udid: "U1", udidPorts: [8128, 8126]), 8126)
        XCTAssertEqual(try MCPServer.reconcilePort(8128, udid: "U1", udidPorts: [8128, 8126]), 8128)
    }

    /// 食い違いの失敗文は**その udid の全ポート**を挙げる(1本だけ名指しすると、読み手が
    /// 「その port へ変えれば直る」と誤読して別エンジンのブリッジへ移ってしまう)
    func testUDIDPortMismatchListsAllPorts() throws {
        XCTAssertThrowsError(try MCPServer.reconcilePort(9999, udid: "U1", udidPorts: [8128, 8126])) {
            XCTAssertTrue($0.localizedDescription.contains("8128, 8126"), $0.localizedDescription)
        }
    }

    /// udid だけならその port を採る
    func testUDIDAloneResolvesToItsPort() throws {
        XCTAssertEqual(try MCPServer.reconcilePort(nil, udid: "U1", udidPorts: [8130]), 8130)
    }

    /// ブリッジが無い udid は**理由を言って失敗する**(黙って既定ポートへ逸れない)
    func testUDIDWithoutABridgeFails() {
        XCTAssertThrowsError(try MCPServer.reconcilePort(nil, udid: "U1", udidPorts: [])) {
            XCTAssertTrue($0.localizedDescription.contains("no running bridge is on udid"),
                          $0.localizedDescription)
        }
    }

    /// どちらも無ければ nil(従来どおり既定ポート → 探索の順で決まる)
    func testNeitherUDIDNorPortLeavesTheChoiceToTheResolver() async throws {
        let resolved = try await MCPServer.portForIOS([:])
        XCTAssertNil(resolved)
    }

    /// port だけなら従来どおりそのまま使う
    func testPortAloneIsUsedAsIs() async throws {
        let resolved = try await MCPServer.portForIOS(["port": 8199])
        XCTAssertEqual(resolved, 8199)
    }

    /// H-3: ブリッジの無い iOS 機は行から判別できる
    func testDeviceRowSaysWhenThereIsNoBridge() {
        let row = DeviceInventory.Row(name: "iPhone 17 Pro", platform: "ios",
                                      identifier: "UDID-1", running: true, physical: false,
                                      registered: false, bridges: [])
        XCTAssertTrue(DeviceInventory.line(row).contains("no bridge"), DeviceInventory.line(row))
        let withBridge = DeviceInventory.Row(name: "iPhone 17 Pro", platform: "ios",
                                             identifier: "UDID-1", running: true, physical: false,
                                             registered: false,
                                             bridges: [DeviceInventory.Row.Bridge(port: 8123, engine: nil)])
        XCTAssertTrue(DeviceInventory.line(withBridge).contains("bridge port 8123"))
        XCTAssertFalse(DeviceInventory.line(withBridge).contains("no bridge"))
    }
}
