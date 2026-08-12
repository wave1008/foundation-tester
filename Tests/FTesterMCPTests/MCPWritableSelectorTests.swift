// 「印字したセレクタが、そのまま書いて当たるか」を固定する。
//
// MCP の出力はシナリオへ書く文字列を供給するためにある。**当たらないセレクタを勧めるのは
// 黙っているより悪い** —— 読み手はそれをコードへ写し、デバイス実行まで誤りに気付けない。
// B(曖昧ラベル注記)と E(操作系の戻り値)は同じ `SelectorNaming` を通るので、ここで縛れば両方が守られる。

import XCTest
import FTCore
import FTDSL
@testable import ftester_mcp

final class MCPWritableSelectorTests: XCTestCase {

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    private func fixtureNames() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// 出したセレクタが**その要素ただ1つ**に解決すること。判定は DSL 本体の `matchDetailed`
    /// (`[n]` の適用まで含めて「1つを選ぶ」規則そのもの)を通す —— 自前で照合を書くと、
    /// 助言と実行で別の解釈になったことに気付けない。
    /// **`resolvedCandidates` は使わない**: あちらは添字を適用する前の候補列なので、
    /// 正しいスコープ記法を「曖昧」と誤判定する(2026-08-09 に実際に踏んだ)
    private func resolvedRef(_ selector: String, in snapshot: SnapshotResponse) -> Int? {
        let locator = FTSelector.parse(selector).primary
        return StepExecutor.matchDetailed(locator, elements: snapshot.elements)?.0.ref
    }

    // MARK: - 実アプリのコーパス全数(想定した形しか試さない自前の例では足りない)

    func testEverySuggestedSelectorResolvesToExactlyThatElement() throws {
        var suggested = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let selector = naming.selector(for: element, in: snapshot) else { continue }
                suggested += 1
                XCTAssertEqual(resolvedRef(selector, in: snapshot), element.ref,
                               "\(name): [\(element.ref)] に勧めた \(selector) が別の要素に解決する")
            }
        }
        XCTAssertGreaterThan(suggested, 100, "1件も勧めていない = このテストは何も検証していない")
    }

    /// 優先順(#id > 一意ラベル > スコープ記法)
    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "button", id: String? = nil,
                         label: String? = nil, depth: Int = 2, y: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 100, height: 40), depth: depth)
    }

    func testUniqueIDWins() throws {
        let snap = snapshot([element(1, id: "login", label: "OK"), element(2, label: "OK")])
        XCTAssertEqual(MCPServer.SelectorNaming(snap).selector(for: snap.elements[0], in: snap),
                       "#login")
    }

    func testUniqueLabelIsUsedWhenThereIsNoUsableID() throws {
        let snap = snapshot([element(1, id: "row", label: "送信"), element(2, id: "row", label: "戻る")])
        // #row は2件あるので使えない → 一意なラベルへ落ちる
        XCTAssertEqual(MCPServer.SelectorNaming(snap).selector(for: snap.elements[0], in: snap),
                       "送信")
    }

    /// **切り詰め表示になるラベルは勧めない**(印字が "…" 付きになり完全一致が必ず外れる)
    func testOverlongLabelIsNotSuggested() throws {
        let long = String(repeating: "あ", count: SnapshotRenderer.labelDisplayLimit + 1)
        let snap = snapshot([element(1, label: long)])
        XCTAssertNil(MCPServer.SelectorNaming(snap).selector(for: snap.elements[0], in: snap))
    }

    // MARK: - 索引に落ちる前に絞る(2026-08-12 の実アプリ監査)

    /// **ラベルが重複していても、型で1つに絞れるなら索引形にしない**。
    /// 実測(Google マップの検索候補)では `#typed_suggest_container >> .clickable[3]` しか
    /// 書けず、候補の件数が変わると別の駅を選んでいた
    func testTypeNarrowsADuplicatedLabelBeforeFallingBackToAnIndex() throws {
        let snap = snapshot([
            element(1, type: "other", id: "suggest", depth: 1),
            element(2, type: "clickable", label: "東京駅", depth: 2, y: 100),
            element(3, type: "staticText", label: "東京駅", depth: 3, y: 100),
        ])
        let naming = MCPServer.SelectorNaming(snap)
        XCTAssertEqual(naming.selector(for: snap.elements[1], in: snap), ".clickable&&東京駅")
        XCTAssertEqual(naming.graded(for: snap.elements[1], in: snap)?.durability, .stable)
        XCTAssertEqual(resolvedRef(".clickable&&東京駅", in: snap), 2)
    }

    /// 型でも絞れないならスコープで絞る。**位置に依存しないので stable**
    func testScopeNarrowsWhenTheTypeCannot() throws {
        let snap = snapshot([
            element(1, type: "other", id: "row_a", depth: 1),
            element(2, type: "button", label: "お気に入りに追加", depth: 2, y: 100),
            element(3, type: "other", id: "row_b", depth: 1),
            element(4, type: "button", label: "お気に入りに追加", depth: 2, y: 200),
        ])
        let naming = MCPServer.SelectorNaming(snap)
        let graded = try XCTUnwrap(naming.graded(for: snap.elements[1], in: snap))
        XCTAssertEqual(graded.selector, "#row_a >> お気に入りに追加")
        XCTAssertEqual(graded.durability, .stable, "兄弟の増減では別物を指さないので stable")
        XCTAssertEqual(resolvedRef("#row_a >> お気に入りに追加", in: snap), 2)
    }

    /// **絞れないものを絞れたことにしない**: 同じ型・同じラベルが2つあり、スコープにできる
    /// 祖先も無いなら「書けない」。`picksExactly` は先頭一致を見るだけなので、
    /// これを `picksOnlyOne` で塞がないと**群の1件目にだけ**嘘の助言が出る
    func testAmbiguousTypeAndLabelIsNotSuggestedForTheFirstOfTheGroup() throws {
        let snap = snapshot([element(1, type: "clickable", label: "経路", depth: 1, y: 100),
                             element(2, type: "clickable", label: "経路", depth: 1, y: 200)])
        let naming = MCPServer.SelectorNaming(snap)
        XCTAssertNil(naming.selector(for: snap.elements[0], in: snap),
                     "先頭だからといって .clickable&&経路 を勧めてはいけない")
        XCTAssertNil(naming.selector(for: snap.elements[1], in: snap))
    }

    /// **スコープにする id は画面で一意でなければならない**。重複した id を容器に使うと
    /// `#row >> 追加` は「**最初の** #row の中の追加」になり、この木ではたまたま当人へ
    /// 解決する —— 検証(`picksOnlyOne`)を通ってしまうので、**引く前の規則で弾く**必要がある。
    /// (`uniqueScopeID` の id 一意チェックを外すと、ここだけが落ちる)
    func testDuplicatedContainerIDIsNeverUsedAsAScope() throws {
        let snap = snapshot([
            element(1, type: "other", id: "row", depth: 1, y: 0),
            element(2, type: "button", label: "追加", depth: 2, y: 10),
            element(3, type: "other", id: "row", depth: 1, y: 200),
            element(4, type: "button", label: "追加", depth: 2, y: 210),
        ])
        XCTAssertNil(MCPServer.uniqueScopeID(for: snap.elements[1], in: snap))
        XCTAssertNil(MCPServer.SelectorNaming(snap).selector(for: snap.elements[1], in: snap),
                     "重複 id をスコープにした式を勧めてはいけない")
    }

    /// **記法として読まれてしまうラベルには `=` 逃がしを使う**。`#` 始まりのラベルを素で書くと
    /// id フィルタとして解釈され、当たらないか別の要素に当たる。
    /// (実アプリのコーパスにこの形が1つも無いので、合成の木でだけ通る経路)
    func testLabelThatLooksLikeNotationFallsBackToTheEscapedForm() throws {
        let snap = snapshot([element(1, label: "#hashtag"), element(2, label: "ほか")])
        let naming = MCPServer.SelectorNaming(snap)
        XCTAssertEqual(naming.selector(for: snap.elements[0], in: snap), "=#hashtag")
        XCTAssertEqual(resolvedRef("=#hashtag", in: snap), 1)
        // 素の形は id として読まれるので、この木では誰にも当たらない
        XCTAssertNil(resolvedRef("#hashtag", in: snap))
    }

    /// **既存の提案を動かさない**: `#id` と一意ラベルは新しい形より優先されたまま
    func testNarrowingFormsDoNotOutrankIDsOrUniqueLabels() throws {
        let snap = snapshot([element(1, id: "login", label: "OK"), element(2, label: "OK"),
                             element(3, label: "送信")])
        let naming = MCPServer.SelectorNaming(snap)
        XCTAssertEqual(naming.selector(for: snap.elements[0], in: snap), "#login")
        XCTAssertEqual(naming.selector(for: snap.elements[2], in: snap), "送信")
    }

    func testScopedNotationIsTheLastResort() throws {
        let snap = snapshot([
            element(1, type: "other", id: "tabs", depth: 1),
            element(2, type: "clickable", depth: 2),
            element(3, type: "clickable", depth: 2),
        ])
        let naming = MCPServer.SelectorNaming(snap)
        // **1番目は添字を書かない**(2026-08-10): 下書きは locator を書き戻すので `[1]` は
        // そこで落ちる。勧める側も落とした形にしておかないと、注記とコードで別の文字列になる。
        // 意味は変わらない(添字なし = 最初の一致)ので、下の resolvedRef で当人が返ることを見る
        XCTAssertEqual(naming.selector(for: snap.elements[1], in: snap), "#tabs >> .clickable")
        XCTAssertEqual(naming.selector(for: snap.elements[2], in: snap), "#tabs >> .clickable[2]")
        XCTAssertEqual(resolvedRef("#tabs >> .clickable", in: snap), 2)
        XCTAssertEqual(resolvedRef("#tabs >> .clickable[2]", in: snap), 3)
    }

    /// 書けないなら nil(黙って当たらないものを返さない)
    func testNoStableSelectorYieldsNil() throws {
        let snap = snapshot([element(1, type: "clickable", depth: 1),
                             element(2, type: "clickable", depth: 1)])
        XCTAssertNil(MCPServer.SelectorNaming(snap).selector(for: snap.elements[0], in: snap))
    }

    // MARK: - B: 曖昧ラベル注記

    func testAmbiguousNoteOffersAWritableSelectorForEveryMatch() throws {
        let snap = snapshot([
            element(1, id: "home_tab", label: "経路", y: 10),
            element(2, id: "route_tab", label: "経路", y: 60),
        ])
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertTrue(note.contains("Write one of these instead"), note)
        XCTAssertTrue(note.contains("[1] #home_tab"), note)
        XCTAssertTrue(note.contains("[2] #route_tab"), note)
    }

    /// **無言のケースを作らない**: 書けない要素は明示する。
    /// **群の全員が「そもそも書けない」なら圧縮形になる**(compactGroupLine の条件1。
    /// 2026-08-12 に追加): 個別の「—」ではなく、ref を並べて理由をひと言にまとめる
    func testAmbiguousNoteMarksElementsThatHaveNoSelector() throws {
        let snap = snapshot([element(1, type: "clickable", label: "経路", depth: 1),
                             element(2, type: "clickable", label: "経路", depth: 1)])
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertTrue(note.contains("[1]"), note)
        XCTAssertTrue(note.contains("[2]"), note)
        XCTAssertTrue(note.contains("none of these have a selector on this screen"), note)
        XCTAssertFalse(note.contains("[1] —"), "全員が書けないので個別の「—」ではなく圧縮形のはず: \(note)")
    }

    /// B-3: 入れ子の一本鎖(容器とその中身が同じラベル)は曖昧ではないので鳴らさない
    func testSingleChainIsStillNotReported() throws {
        let snap = snapshot([
            element(1, type: "button", id: "tile", label: "自宅、追加", depth: 1),
            element(2, type: "other", id: "inner", label: "自宅、追加", depth: 2),
        ])
        XCTAssertEqual(MCPServer.ambiguousLabelsNote(snap), "")
    }

    /// B-2: 打ち切ったことを明示する(黙って切ると「これで全部」と読まれる)
    func testAmbiguousNoteSaysWhenItTruncated() throws {
        var elements: [ElementInfo] = []
        var ref = 1
        for label in ["a", "b", "c", "d", "e", "f"] {
            for _ in 0..<2 {
                elements.append(element(ref, type: "button", label: label, depth: 1,
                                        y: Double(ref) * 10))
                ref += 1
            }
        }
        let note = MCPServer.ambiguousLabelsNote(snapshot(elements))
        XCTAssertTrue(note.contains("more ambiguous label(s) not shown"), note)
    }

    func testAmbiguousNoteSaysWhenAnIndividualLabelHasTooManyMatches() throws {
        let elements = (1...9).map { element($0, type: "button", label: "同じ", depth: 1,
                                             y: Double($0) * 10) }
        let note = MCPServer.ambiguousLabelsNote(snapshot(elements))
        XCTAssertTrue(note.contains("more matches not shown"), note)
    }

    /// 群のどの候補も安定したセレクタを書けないとき、その事実を明示する
    /// (index-based の "~" と「そもそも書けない」の両方を「安定は無い」として拾う)
    func testAmbiguousNoteSaysWhenNoCandidateHasAStableSelector() throws {
        let snap = snapshot([element(1, type: "clickable", label: "経路", depth: 1),
                             element(2, type: "clickable", label: "経路", depth: 1)])
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertTrue(note.contains(
            "none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these."), note)
    }

    /// 群の中に安定セレクタを持つ候補が1件でもあれば、上の明示は出さない
    func testAmbiguousNoteOmitsTheNoStableSelectorLineWhenACandidateIsStable() throws {
        let snap = snapshot([
            element(1, id: "home_tab", label: "経路", y: 10),
            element(2, id: "route_tab", label: "経路", y: 60),
        ])
        let note = MCPServer.ambiguousLabelsNote(snap)
        XCTAssertFalse(note.contains("prefer tapping by ref for these."), note)
    }

    // MARK: - C: 重複 id 注記の「安定なし」明示

    /// duplicateIDsNote 版: どの候補も安定したセレクタを書けないとき明示する
    func testDuplicateIDsNoteSaysWhenNoCandidateHasAStableSelector() throws {
        let snap = snapshot([
            element(1, type: "textField", id: "numberpicker_input", depth: 1),
            element(2, type: "textField", id: "numberpicker_input", depth: 1),
        ])
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertTrue(note.contains(
            "none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these."), note)
    }

    /// duplicateIDsNote 版: 各要素が別々の一意ラベルを持ち、それぞれ安定に書けるなら明示しない
    func testDuplicateIDsNoteOmitsTheNoStableSelectorLineWhenACandidateIsStable() throws {
        let snap = snapshot([
            element(1, type: "textField", id: "numberpicker_input", label: "時", depth: 1),
            element(2, type: "textField", id: "numberpicker_input", label: "分", depth: 1),
        ])
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertFalse(note.contains("prefer tapping by ref for these."), note)
    }
}

/// E: 操作系の戻り値に「その操作を再現するセレクタ」が必ず入ること。
/// **ref だけ返すのは黙って情報を捨てるのと同じ** —— ref はセッション限りの番号で
/// シナリオには書けない。
final class MCPReproductionSelectorTests: XCTestCase {

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

    /// FakeDriver の既定の木は `#login_btn` を1件だけ持つ = 一意な id が出るはず
    func testTapNamesTheSelectorThatReproducesIt() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("(selector: #login_btn)"), text)
    }

    /// 安定セレクタが無いなら**明示する**(黙って ref だけ返さない)
    func testTapSaysWhenThereIsNoStableSelector() async throws {
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
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("no stable selector for this element"), text)
    }

    /// E-4: 座標には出せる根拠が無いので、出さずに断る
    func testCoordinateTapRefusesToGuessASelector() async throws {
        let text = body(try await server.call(tool: "ft_tap", args: ["x": 10.0, "y": 20.0]))
        XCTAssertTrue(text.contains("coordinates cannot be reproduced by selector"), text)
        XCTAssertFalse(text.contains("(selector:"), text)
    }

    /// **ref を受ける操作系すべて**に入る(1つでも漏れると、その道具を使った手だけ書けない)
    func testEveryRefTakingToolNamesASelector() async throws {
        for (tool, args) in [("ft_tap", ["ref": 1] as [String: Any]),
                             ("ft_press", ["ref": 1]),
                             ("ft_double_tap", ["ref": 1]),
                             ("ft_clear_input", ["ref": 1]),
                             ("ft_type", ["ref": 1, "text": "abc"]),
                             ("ft_drag", ["fromRef": 1, "dy": -50.0]),
                             ("ft_pinch", ["ref": 1, "scale": 2.0])] {
            _ = try await server.call(tool: "ft_snapshot", args: [:])
            let text = body(try await server.call(tool: tool, args: args))
            XCTAssertTrue(text.contains("(selector: #login_btn)"),
                          "\(tool) がセレクタを返していない: \(text)")
        }
    }
}
