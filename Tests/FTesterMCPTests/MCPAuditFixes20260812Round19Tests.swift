// 19回目の実アプリ監査(赤羽→立川・Apple マップ / Google マップ)由来の改善5件:
//   ① シート展開救済が効かないと分かった画面を覚え、同じ画面の2回目では撃たない(sheetRescueKey)
//   ② シート由来の失敗に「手で開く手順」を ref 付きで添える(sheetManualExpandHint)
//   ③ 木は変わったのに主役のスクロール容器が空 = 読み込み中を1回だけ待ち直す(emptyLoadingScroller)
//   ④ 全群が畳まれた曖昧注記で、末尾の総括を重ねない(renderGroups)
//   ⑤ 探索停止時の「見えているもの」一覧で、地図ピン等の飾り葉を後回しにする(actionableFirst)
//   ⑥ 畳んだ同一id群の注記は初回だけ満額(bulkExemptNote)

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPAuditFixes20260812Round19Tests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func snapshot(_ elements: [ElementInfo],
                          bulkExempt: Int? = nil) -> SnapshotResponse {
        var response = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                        elements: elements, truncatedCount: 0)
        response.bulkExemptCount = bulkExempt
        return response
    }

    private func element(_ ref: Int, type: String = "other", id: String? = nil,
                         label: String? = nil, frame: FTRect, depth: Int = 1,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth,
                    scrollable: scrollable)
    }

    // MARK: - ③ 中身の来ていないスクロール容器

    /// **本丸**: 画面の主役を占めるスクロール容器に子が1つも無ければ「読み込み中」として名指しする
    /// (実測: Google マップの経路検索で #expandingscrollview_container が子ゼロのまま返り、
    /// 経路一覧は次の ft_snapshot で初めて出た)
    func testEmptyMainScrollerIsReportedAsLoading() {
        let tree = snapshot([
            element(1, id: "header", frame: FTRect(x: 0, y: 0, width: 402, height: 100)),
            element(2, type: "scrollView", id: "results", frame: FTRect(x: 0, y: 100,
                                                                        width: 402, height: 700),
                    scrollable: true),
        ])
        let found = MCPServer.emptyLoadingScroller(in: tree)
        XCTAssertEqual(found?.identifier, "results")
    }

    /// 子が1件でも入っていれば描画は始まっている = 待たない
    func testScrollerWithAChildIsNotReportedAsLoading() {
        let tree = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true),
            element(2, id: "row", label: "1件目",
                    frame: FTRect(x: 0, y: 110, width: 402, height: 60), depth: 2),
        ])
        XCTAssertNil(MCPServer.emptyLoadingScroller(in: tree))
    }

    /// 小さな帯(フィルタの横並び等)の空は正常。**画面の3割**に満たない容器は見ない
    func testSmallEmptyScrollerIsIgnored() {
        let tree = snapshot([
            element(1, type: "collectionView", id: "chips",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 100), scrollable: true),
        ])
        XCTAssertNil(MCPServer.emptyLoadingScroller(in: tree))
    }

    /// `scrollable` 申告が無い容器は見ない(false = スクロール不可 とは読めない契約なので、
    /// **true を見つけたときだけ**使う。ElementInfo.scrollable の宣言参照)
    func testUndeclaredScrollerIsIgnored() {
        let tree = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700)),
        ])
        XCTAssertNil(MCPServer.emptyLoadingScroller(in: tree))
    }

    /// 容器のあとに**同じ深さ以下**の要素しか無い場合も「子なし」(preorder の走査規則)
    func testSiblingAfterScrollerIsNotCountedAsChild() {
        let tree = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 2,
                    scrollable: true),
            element(2, id: "footer", label: "脚注",
                    frame: FTRect(x: 0, y: 810, width: 402, height: 40), depth: 2),
        ])
        XCTAssertEqual(MCPServer.emptyLoadingScroller(in: tree)?.identifier, "results")
    }

    /// **発火する画面を集合で固定する砦**(CLAUDE.md「新しい検知は既存資産の全数に当てて
    /// 誤検知0まで確認する」)。実アプリのコーパスは**すべて描画の済んだ画面**なので、
    /// 「読み込み中かもしれない」と言うのは原則すべて誤検知 —— 緩ければ操作のたびに
    /// 0.4 秒の空待ちと誤った注記を払う。判定が depth の入れ子に依存しているので、
    /// **depth を平坦に送るブリッジが混じったらここが落ちる**(その時は述語ではなく前提を疑う)。
    ///
    /// **等号で照合する**(2026-08-12 に nil 固定から変更): アーキタイプを広げたとき
    /// `ios-messages_keyboard` で発火した。検分の結果**述語としては誤検知だが、実害は
    /// 小さいと判断して現状を固定する**:
    /// - 会話に1件もメッセージが無い状態で、`#TranscriptCollectionView`(0,0 402x874 =
    ///   全画面の器)が子ゼロで返る。**全画面の器は入れ子の兄弟しか持たない**ので、
    ///   「子が無い」は中身が無いことを意味しない —— 述語の穴はここ
    /// - 払うのは1回きりの短い待ちと、「本当に空かもしれない」と明記した注記だけ
    ///   (throw も再試行もしない。emptyLoadingScroller の宣言参照)
    ///
    /// **述語を絞るなら、地図側の witness(`#expandingscrollview_container`)を
    /// フィクスチャに採ってからにすること** —— それが無いまま「全画面の器を除く」と
    /// 絞ると、この検知が生まれた動機の形を落としたことに気付けない
    static let knownEmptyScrollerFirings: Set<String> = ["ios-messages_keyboard.json"]

    func testNoFalsePositiveOnTheRealAppCorpus() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 25, "コーパスが痩せていると砦にならない")
        var fired: [String: String] = [:]
        for name in names {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let tree = try JSONDecoder().decode(SnapshotResponse.self, from: data)
            if let found = MCPServer.emptyLoadingScroller(in: tree) {
                fired[name] = RefGuard.describe(found)
            }
        }
        XCTAssertEqual(Set(fired.keys), Self.knownEmptyScrollerFirings,
                       "「空の読み込み中容器」と判定される画面の集合が変わった(実測 \(fired))。"
                       + " 増えたなら述語が緩い。減ったなら述語を絞った副作用が出ていないか見ること")
    }

    // MARK: - ③ 配線(snapshotAfter の実経路)

    /// **本丸の配線**: 木は操作前と別物なのに主役の容器が空 → 1回だけ待って撮り直し、
    /// 埋まった木を返す。既存の settle-lite(操作前と同一のときだけ待つ)は木が変わって
    /// いるので発火せず、この形は素通りしていた
    func testSnapshotAfterReReadsWhenTheMainScrollerIsStillEmpty() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        let before = snapshot([element(1, type: "button", id: "go", label: "検索",
                                       frame: FTRect(x: 0, y: 0, width: 402, height: 40))])
        let empty = snapshot([
            element(1, type: "button", id: "back", label: "戻る",
                    frame: FTRect(x: 0, y: 0, width: 402, height: 40)),
            element(2, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true),
        ])
        let filled = snapshot([
            element(1, type: "button", id: "back", label: "戻る",
                    frame: FTRect(x: 0, y: 0, width: 402, height: 40)),
            element(2, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true),
            element(3, type: "staticText", id: "route", label: "埼京線",
                    frame: FTRect(x: 0, y: 110, width: 402, height: 60), depth: 2),
        ])
        driver.scriptedSnapshots = [before, empty, filled]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_tap",
                                            args: ["x": 1.0, "y": 2.0, "snapshotAfter": true])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("was still empty right after the action"), text)
        XCTAssertTrue(text.contains("id=route"), text)
    }

    /// 埋まらなかったら**断定しない**: 正当に空(検索結果0件)のこともあるので、
    /// 「まだ読み込み中かもしれない」と言うだけで waitFor の判断は読み手に渡す
    func testSnapshotAfterStaysHonestWhenTheScrollerNeverFills() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        let before = snapshot([element(1, type: "button", id: "go", label: "検索",
                                       frame: FTRect(x: 0, y: 0, width: 402, height: 40))])
        let empty = snapshot([
            element(1, type: "button", id: "back", label: "戻る",
                    frame: FTRect(x: 0, y: 0, width: 402, height: 40)),
            element(2, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true),
        ])
        driver.scriptedSnapshots = [before, empty, empty]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(tool: "ft_tap",
                                            args: ["x": 1.0, "y": 2.0, "snapshotAfter": true])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("still empty after a short re-read wait"), text)
        XCTAssertTrue(text.contains("may"), text)
        XCTAssertFalse(text.contains("was still empty right after the action"), text)
    }

    /// 中身の入った容器では余計な待ちを払わない(snapshot は1回だけ)
    func testSnapshotAfterDoesNotWaitWhenTheScrollerHasContent() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        let before = snapshot([element(1, type: "button", id: "go", label: "検索",
                                       frame: FTRect(x: 0, y: 0, width: 402, height: 40))])
        let filled = snapshot([
            element(1, type: "scrollView", id: "results",
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true),
            element(2, type: "staticText", id: "route", label: "埼京線",
                    frame: FTRect(x: 0, y: 110, width: 402, height: 60), depth: 2),
        ])
        driver.scriptedSnapshots = [before, filled, filled]
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let callsBefore = driver.calls.count
        _ = try await server.call(tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true])
        XCTAssertEqual(driver.calls[callsBefore...].filter { $0 == "snapshot" }.count, 1,
                       "\(driver.calls)")
    }

    // MARK: - ①② シート救済の記憶と手順

    /// 救済が効かない画面の鍵は**木の指紋**。同じ木なら同じ鍵・違う木なら違う鍵
    /// (画面が変われば記憶は自然に失効する)
    func testSheetRescueKeyFollowsTheTree() {
        let a = snapshot([element(1, id: "row_1", label: "A",
                                  frame: FTRect(x: 0, y: 0, width: 402, height: 60))])
        let b = snapshot([element(1, id: "row_1", label: "A",
                                  frame: FTRect(x: 0, y: 0, width: 402, height: 60))])
        let c = snapshot([element(1, id: "row_2", label: "B",
                                  frame: FTRect(x: 0, y: 0, width: 402, height: 60))])
        XCTAssertEqual(MCPServer.sheetRescueKey(a), MCPServer.sheetRescueKey(b))
        XCTAssertNotEqual(MCPServer.sheetRescueKey(a), MCPServer.sheetRescueKey(c))
    }

    /// **本丸**: グラバーを名指しできる画面では、手で開く具体手順(ft_drag fromRef + toY)を出す
    func testManualExpandHintNamesTheGrabberAndTarget() {
        let tree = snapshot([
            element(9, type: "button", id: "Card grabber", label: "カードコントローラ",
                    frame: FTRect(x: 152, y: 637, width: 96, height: 23)),
        ])
        let hint = MCPServer.sheetManualExpandHint(tree)
        XCTAssertTrue(hint.contains("ft_drag fromRef: 9"), hint)
        XCTAssertTrue(hint.contains("toY: \(Int((874 * MCPServer.expandedSheetTopRatio).rounded()))"),
                      hint)
        XCTAssertTrue(hint.contains("ft_snapshot"), hint)
    }

    /// グラバーを名指しできない画面では黙る(当てずっぽうの座標ドラッグは勧めない)
    func testManualExpandHintStaysSilentWithoutAGrabber() {
        let tree = snapshot([element(1, type: "button", id: "ok", label: "OK",
                                     frame: FTRect(x: 0, y: 700, width: 100, height: 40))])
        XCTAssertEqual(MCPServer.sheetManualExpandHint(tree), "")
    }

    // MARK: - ④ 曖昧注記の重複した総括

    /// **本丸**: 全群が「畳んだ1行(tap by ref instead)」で出たなら、末尾の総括は重ねない
    func testAllCompactGroupsDropTheRedundantFooter() {
        // 同じ容器に並ぶ同型セル: 代替セレクタは index-based しか作れない = 全群が畳まれる
        var elements: [ElementInfo] = [
            element(1, type: "collectionView", id: "list",
                    frame: FTRect(x: 0, y: 0, width: 402, height: 800), depth: 1),
        ]
        for i in 0..<4 {
            elements.append(element(10 + i, type: "staticText", label: "埼京線",
                                    frame: FTRect(x: 0, y: Double(i) * 100,
                                                  width: 200, height: 40), depth: 2))
        }
        let note = MCPServer.ambiguousLabelsNote(snapshot(elements))
        XCTAssertTrue(note.contains("tap by ref instead"), note)
        XCTAssertFalse(note.contains("none of the above have a stable selector"), note)
    }

    // MARK: - ⑤ 探索停止時の一覧

    /// **本丸**: 地図ピン(飾りの葉)が並ぶ画面でも、操作対象の行が先に出る
    func testVisibleLabelsHintPutsActionableRowsFirst() {
        var elements: [ElementInfo] = []
        // 飾りの葉を先に大量に置く(ツリー順は地図が先 = 修正前はこれで20枠が埋まっていた)
        for i in 0..<25 {
            elements.append(element(100 + i, id: "VKPointFeature", label: "セブン‐イレブン\(i)",
                                    frame: FTRect(x: Double(i), y: 200, width: 30, height: 30),
                                    depth: 3))
        }
        elements.append(element(9, type: "button", id: "btn_next", label: "次へ",
                                frame: FTRect(x: 0, y: 700, width: 100, height: 40), depth: 2))
        let hint = MCPServer.visibleLabelsHint(snapshot(elements))
        XCTAssertTrue(hint.contains("#btn_next"), hint)
    }

    // MARK: - ⑦ 宛先から platform を読む

    /// **本丸**(2026-08-12 にデバイスで踏んだ実バグ): `serial` だけを渡した呼び出しが
    /// 既定の "ios" に落ち、**黙って iOS の画面を返していた**。エラーにならないので、
    /// 読み手は別プラットフォームの木を正解として読む
    func testSerialAloneResolvesToAndroid() {
        XCTAssertEqual(MCPServer.platformName(["serial": "emulator-5554"]), "android")
    }

    /// udid / port だけの呼び出しは iOS
    func testIOSTargetAloneResolvesToIOS() {
        XCTAssertEqual(MCPServer.platformName(["port": 8123]), "ios")
        XCTAssertEqual(MCPServer.platformName(["udid": "ABC"]), "ios")
    }

    /// **明示 platform が常に勝つ**(推論は明示を上書きしない)
    func testExplicitPlatformWinsOverTheTarget() {
        XCTAssertEqual(MCPServer.platformName(["platform": "ios", "serial": "emulator-5554"]), "ios")
        XCTAssertEqual(MCPServer.platformName(["platform": "android", "port": 8123]), "android")
    }

    /// 空文字の serial は「指定なし」(明示ターゲット述語と同じ規約)。既定へ落ちる
    func testEmptySerialFallsBackToTheDefault() {
        XCTAssertEqual(MCPServer.platformName(["serial": ""]), "ios")
        XCTAssertEqual(MCPServer.platformName([:]), "ios")
    }

    /// **ドライバ選択と鍵が同じ解決を使う**: 食い違うと「Android を作って iOS の鍵で覚える」
    /// (ref 世代・キャッシュ・記憶が全部ずれる)
    func testEngineKeyFollowsTheSameResolution() {
        XCTAssertTrue(MCPServer.engineKey(["serial": "emulator-5554"]).contains("android"))
        XCTAssertFalse(MCPServer.engineKey(["serial": "emulator-5554"]).contains("ios"))
    }

    // MARK: - ⑥ 畳んだ群の注記

    /// 初回は満額・以後は件数だけ(実体が木の1行なのに注記が長い、の逆転を止める)
    func testBulkExemptNoteShrinksAfterTheFirstTime() {
        let tree = snapshot([element(1, id: "a", label: "A",
                                     frame: FTRect(x: 0, y: 0, width: 10, height: 10))],
                            bulkExempt: 91)
        let full = MCPServer.bulkExemptNote(tree)
        let short = MCPServer.bulkExemptNote(tree, abbreviated: true)
        XCTAssertTrue(full.contains("91"), full)
        XCTAssertTrue(full.contains("expandBulk"), full)
        XCTAssertTrue(short.contains("91"), short)
        XCTAssertFalse(short.contains("expandBulk"), short)
        XCTAssertLessThan(short.count, full.count / 2)
    }

    /// 申告の無いブリッジでは黙る(短縮形でも嘘の安心を出さない)
    func testBulkExemptNoteStaysSilentWithoutADeclaration() {
        let tree = snapshot([element(1, id: "a", label: "A",
                                     frame: FTRect(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertEqual(MCPServer.bulkExemptNote(tree), "")
        XCTAssertEqual(MCPServer.bulkExemptNote(tree, abbreviated: true), "")
    }
}
