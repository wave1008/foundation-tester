// セレクタの**耐久性の格付け**(2026-08-10)。
//
// 「書ける」と「壊れにくい」は別物。`#id` と一意ラベルは木が変わっても指し続けるが、
// `#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで別要素を指す**。
// 同じ一覧に無印で混ぜると生成器は先頭を採るだけなので、印と但し書きで差を出す。
//
// 検知の類なので**両方向**を固定する: 添字付きに印が付くこと / 安定側に印が付かないこと。

import XCTest
import FTCore
import FTDSL
@testable import ftester_mcp

final class MCPSelectorDurabilityTests: XCTestCase {

    private func fixtureNames() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    // MARK: - 印と但し書きの対応

    func testMarkAndCautionOnlyOnIndexed() {
        XCTAssertEqual(MCPServer.Durability.indexed.mark, "~")
        XCTAssertTrue(MCPServer.Durability.indexed.caution.contains("index-based"))
        // **安定側は無印**: 印が付くのは注意が要るものだけ、が読みやすい
        XCTAssertEqual(MCPServer.Durability.stable.mark, "")
        XCTAssertEqual(MCPServer.Durability.stable.caution, "")
        XCTAssertNotNil(MCPServer.indexedSelectorNote(.indexed))
        XCTAssertNil(MCPServer.indexedSelectorNote(.stable))
    }

    // MARK: - 実アプリのコーパス全数

    /// `scopedSelector`(`#容器 >> .型[n]`)から採った式は**綴りに `[n]` が出なくても** indexed。
    /// `#容器 >> .clickable` は「容器の中の最初の clickable」で、位置依存は消えていない ——
    /// 綴りで判定していた版はこの形だけを取りこぼして無印にしていた(2026-08-10)。
    ///
    /// **判定は綴りではなく出所**(2026-08-12): `>>` を含むかで見ていた版は、
    /// 位置に依存しない `#容器 >> ラベル`(スコープ内で一意なラベル)まで indexed だと
    /// 言い張った —— 同じ「綴りで判定するな」の失敗を裏側から踏んでいた
    func testScopedIndexSelectorStaysIndexedEvenWhenTheIndexIsNotSpelledOut() throws {
        var checkedFirstSibling = false
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot),
                      let scoped = MCPServer.scopedSelector(for: element, in: snapshot),
                      graded.selector == scoped || graded.selector == MCPServer.asWritten(scoped)
                else { continue }
                XCTAssertEqual(graded.durability, .indexed,
                               "\(name): \(graded.selector) は添字形なのに stable")
                if !graded.selector.contains("[") { checkedFirstSibling = true }
            }
        }
        XCTAssertTrue(checkedFirstSibling,
                      "添字の出ないスコープ記法がコーパスに1件も無く、この回帰を検証できていない")
    }

    /// **位置に依存しない式は `>>` を含んでも stable**(2026-08-12)。`#容器 >> ラベル` は
    /// 「容器の中のそのラベル」で、兄弟の増減では別物を指さない。
    /// **stable を名乗る式は候補が1件しかないこと**まで確かめる —— `picksExactly` は
    /// 先頭一致を見るだけなので、これが無いと群の1件目にだけ嘘の助言が出る
    func testStableSelectorsAreAlwaysUnambiguous() throws {
        var checkedScopedLabel = false
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot),
                      graded.durability == .stable else { continue }
                XCTAssertTrue(
                    MCPServer.picksOnlyOne(element, with: graded.selector, in: snapshot),
                    "\(name): \(graded.selector) は stable なのに候補が1件ではない")
                if graded.selector.contains(">>") { checkedScopedLabel = true }
            }
        }
        XCTAssertTrue(checkedScopedLabel,
                      "位置に依存しないスコープ式がコーパスに1件も無く、この回帰を検証できていない")
    }

    /// **勧める形と、下書きに実際に書かれる形が一致する**こと。
    /// 判定は `ScenarioCodeGen` 本体(下書きが通るのと同じ経路)に通す —— 自前で往復させると、
    /// `asWritten` が恒等関数に退化しても素通しになる(2026-08-10 に自分で踏んだ)
    func testSuggestedSelectorIsExactlyWhatTheGeneratorWrites() throws {
        var checked = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot) else { continue }
                var step = FlowStep(action: "tap")
                step.locator = FTSelector.parse(graded.selector).primary
                let code = ScenarioCodeGen.render(
                    flow: Flow(name: "t", app: "a", platform: "ios", goal: nil,
                               generatedBy: "test", steps: [step]),
                    className: "T", generatedBy: "test", emptyExpectation: true)
                XCTAssertTrue(code.contains("tap(\"\(graded.selector)\")"),
                              "\(name): 勧めた \(graded.selector) が下書きに"
                                + "そのまま書かれない\n\(code)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// **絞り込みの取り分を守る**(2026-08-12)。`.型&&ラベル` / `#容器 >> ラベル` を足す前は
    /// コーパス 975 要素のうち **indexed 326 / 書けない 38** で、足した後は **150 / 27**。
    /// **上げるときは増えた分を1件ずつ見てから**(黙って上げるとこの砦は現状の追認装置になる。
    /// SweepHarnessTests の基準値と同じ規律)。検分は `FT_SELECTOR_DURABILITY=1` の
    /// 画面別内訳で行う。候補の事前ゲート(数え上げ)はコストだけを下げるもので、
    /// **この数を1件も動かさない**。
    ///
    /// **割合も見る**(2026-08-12 に追加): 絶対数だけだとコーパスを広げるたびに上限を
    /// 上げる儀式になり、砦が「増えたら追認する」装置に退化する。要素あたりの割合は
    /// コーパスの大きさに依らない。
    ///
    /// 2026-08-12 にアーキタイプを6枚足して **150 → 229 / 975 → 1,261 要素**(15.4% → 18.2%)。
    /// 増分 79 の内訳は画面別に検分済みで、**3枚に集中**している:
    /// `ios-settings_root` 23 / `and-dialer_keypad` 22 / `and-settings_root` 21
    /// (残り: safari 10・messages 3・photos 0)。いずれも**行の中の無名の下位ビュー**が
    /// 同じ id で繰り返される形(`#icon`/`#icon_frame`/`#text_frame` ×7、
    /// `#dialpad_key_layout`/`#dialpad_key_number` ×12)で、**ラベルもテキストも無いので
    /// 絞り込みようがない = indexed が正しい格付け**。絞り込みの退行ではなく、
    /// コーパスがその形を含むようになっただけ
    ///
    /// **2026-08-12 にブラウザ4枚を足して 254 → 316 / 1,320 → 1,624 要素**(19% で据え置き)。
    /// 増分 62 と書けない側の増分 24 は**4枚に閉じている**(nationwide 32/6・startpage 30/8・
    /// and-browser_weather 0/9・urlmenu 0/1)。理由は構造的で、**web ページには id が1つも無い**
    /// —— 日本地図の地域リンクや `#favoritesItemIdentifierContent ×8` のようにラベルすら無い
    /// 同型要素が並ぶので、indexed / 書けない が正しい格付けになる。
    /// **割合(19% / 3%)は動いていない** = 絞り込みの退行ではない
    /// **2026-08-12 に週間表(格子)の2枚を足して 316 → 350 / 1,624 → 1,832 要素**(19% で据え置き)。
    /// 増分は**新しい2枚に完全に閉じている**(`ios-browser_weektable` 34/12・
    /// `and-browser_weektable` 0/23 = 索引 +34・書けない +35 が総差分と一致し、他の30枚は不動)。
    /// 理由は格子の形そのもの: **同じ数値ラベルが行と列に何度も出る**(`29/24`×4・`90%`×4・
    /// `雨時々曇`×4)のに web ページなので id が1つも無い。iOS は `#WebView` を持つので
    /// 索引セレクタが書けて indexed、Android は容器の id すら無いので unwritable ——
    /// どちらも**格付けとしては正しい**。
    /// **書けない側の割合は 3% → 4.75% へ動いた**(上限 4% にちょうど乗っている)。
    /// 次に web の格子を足すとこの砦は落ちる —— そのときは同じ検分をやり直すこと
    func testNarrowingKeepsIndexedAndUnwritableLow() throws {
        var indexed = 0, unwritable = 0, total = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                total += 1
                switch naming.graded(for: element, in: snapshot)?.durability {
                case .some(.indexed): indexed += 1
                case .none: unwritable += 1
                case .some(.stable): break
                }
            }
        }
        XCTAssertGreaterThan(total, 1500, "コーパスが縮んでいる = この砦は何も見ていない")
        XCTAssertLessThanOrEqual(indexed, 360, "索引セレクタが増えている(実測 350)")
        // **割合は千分率で見る**(2026-08-12 のレビュー指摘)。百分率の整数除算だと
        // 「4%以下」が実際には 4.99% まで通り、宣言した上限より1ポイント緩い砦になる
        // (実測 4.75% が「4」に切り捨てられて素通りしていた)
        XCTAssertLessThanOrEqual(indexed * 1000 / max(1, total), 200,
                                 "索引セレクタの割合が増えている(実測 19.1%)"
                                 + " —— 画面を足しただけでは上がらない指標なので、絞り込みの退行を疑う")
        XCTAssertLessThanOrEqual(unwritable, 90, "書けない要素が増えている(実測 87)")
        // **書けない側にも割合ゲートを置く**(2026-08-12)。絶対数だけだと、コーパスを
        // 広げるたびに上限を上げる儀式になる(索引側で既に踏んだ轍)
        XCTAssertLessThanOrEqual(unwritable * 1000 / max(1, total), 50,
                                 "書けない要素の割合が増えている(実測 4.75%)")
    }

    /// コーパスに両方の格付けが出ていること(片側しか見ていない状態を防ぐ)
    func testCorpusExercisesBothGrades() throws {
        var stable = 0, indexed = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot) else { continue }
                if graded.durability == .indexed { indexed += 1 } else { stable += 1 }
            }
        }
        XCTAssertGreaterThan(stable, 0)
        XCTAssertGreaterThan(indexed, 0, "添字付きが1件も出ないコーパスでは印の検証にならない")
    }

    /// 上限を上げる前の検分用(`FT_SELECTOR_DURABILITY=1` のときだけ動く)。**どの画面が
    /// 索引セレクタを増やしたか**を出す —— 総数だけ見て上げると現状の追認になる
    func testPrintDurabilityPerFixture() throws {
        guard ProcessInfo.processInfo.environment["FT_SELECTOR_DURABILITY"] == "1" else { return }
        var totalIndexed = 0, totalUnwritable = 0, totalAll = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            var indexed = 0, unwritable = 0
            for element in snapshot.elements {
                switch naming.graded(for: element, in: snapshot)?.durability {
                case .some(.indexed): indexed += 1
                case .none: unwritable += 1
                case .some(.stable): break
                }
            }
            totalIndexed += indexed
            totalUnwritable += unwritable
            totalAll += snapshot.elements.count
            print(String(format: "  %-30s elements=%3d indexed=%3d unwritable=%2d",
                         (name as NSString).utf8String!, snapshot.elements.count,
                         indexed, unwritable))
        }
        print("TOTAL elements=\(totalAll) indexed=\(totalIndexed)"
            + " (\(totalIndexed * 100 / max(1, totalAll))%) unwritable=\(totalUnwritable)")
    }

    /// 曖昧ラベル注記の凡例が印を説明していること(印だけ出て意味が書いていない状態を防ぐ)
    func testAmbiguousNoteExplainsTheMark() throws {
        for name in try fixtureNames() {
            let note = MCPServer.ambiguousLabelsNote(try fixture(name))
            guard !note.isEmpty else { continue }
            XCTAssertTrue(note.contains("\"~\""), "\(name): 凡例に ~ の説明が無い")
            return
        }
        XCTFail("曖昧ラベル注記が1枚も出ないコーパスでは凡例を検証できない")
    }
}
