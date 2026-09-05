// セレクタの**耐久性の格付け**。
//
// 「書ける」と「壊れにくい」は別物。`#id` と一意ラベルは木が変わっても指し続けるが、
// `#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで別要素を指す**。
// 同じ一覧に無印で混ぜると生成器は先頭を採るだけなので、印と但し書きで差を出す。
//
// 検知の類なので**両方向**を固定する: 添字付きに印が付くこと / 安定側に印が付かないこと。

import XCTest
import FTCore
@testable import fleetest_mcp

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
    /// 綴りで判定していた版はこの形だけを取りこぼして無印にしていた。
    ///
    /// **判定は綴りではなく出所**: `>>` を含むかで見ていた版は、
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

    /// **位置に依存しない式は `>>` を含んでも stable**。`#容器 >> ラベル` は
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

    /// **絞り込みの取り分を守る**。`.型&&ラベル` / `#容器 >> ラベル` を足す前は
    /// コーパス 975 要素のうち **indexed 326 / 書けない 38** で、足した後は **150 / 27**。
    /// **上げるときは増えた分を1件ずつ見てから**(黙って上げるとこの砦は現状の追認装置になる。
    /// SweepHarnessTests の基準値と同じ規律)。検分は `FT_SELECTOR_DURABILITY=1` の
    /// 画面別内訳で行う。候補の事前ゲート(数え上げ)はコストだけを下げるもので、
    /// **この数を1件も動かさない**。
    ///
    /// **割合も見る**: 絶対数だけだとコーパスを広げるたびに上限を
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
    /// 次に web の格子を足すとこの砦は落ちる —— そのときは同じ検分をやり直すこと。
    /// **2026-08-13 に予告どおり落ちたので同じ検分をやり直した**(Yahoo!天気の週間画面を両 OS で
    /// 足して 350 → 386 / 1,832 → 1,986 要素)。増分は**やはり新しい2枚に完全に閉じている**
    /// (`ios-browser_weather_weekly` 36/2・`and-browser_weather_weekly` 0/8 = 索引 +36・
    /// 書けない +10 が総差分と一致し、他の32枚は不動)。理由も同じで、web ページなので id が
    /// 無く、iOS は `#WebView` を持つので索引が書けて indexed・Android は容器の id すら無く
    /// unwritable になる。**割合は 19.1% → 19.4% / 4.75% → 4.88%** で、どちらも上限の内側に
    /// 留まった = 絞り込みの退行ではない。**書けない側は上限 5% まであと 0.12 ポイント** ——
    /// 次に Android の web ページを足すと今度は割合ゲートのほうが落ちる
    /// **2026-08-13 に索引側の割合ゲートが初めて落ちた**(386 → 566 /
    /// 1,986 → 2,238 要素)。検分の結論は**退行ではない**: 新しい2枚を外すと既存の基準値
    /// (386 / 19.4% / 97)のまま緑に戻り、増分は `ios-browser_jma_hscroll` 180/16 ・
    /// `and-browser_jma_notree` 0/0 = 索引 +180・書けない +16 が総差分と**完全に一致**する
    /// (他の35枚は不動)。**ただし今回は割合が 19.4% → 25.2% と一段で 5.8 ポイント動いた** ——
    /// これまでの増分(0.3ポイント級)とは桁が違うので理由を明記する:
    /// この木は**横スクロール後の前後コピーを両方含む**(duplicateRegionNote の witness)ため、
    /// **構造上ほぼ全てのラベルが2回以上出る** = 一意に名指せる要素が原理的に存在しない。
    /// 233要素中180(77%)が indexed になるのはこの1枚に固有の事情で、
    /// **コーパス全体の索引率のうち 180/566 = 32% をこの1枚が占める**。
    /// **上流(WebKit)が複製を出さなくなったらこの枚を採り直し、ゲートも締め直すこと** ——
    /// このまま据えると「1枚の病理が全体の基準」になる
    /// **書けない側の割合は 4.88% → 5.04%**(千分率の切り捨てで 50。上限 50 にちょうど乗った)。
    /// 次の1枚で必ず落ちるので、そのときは緩める前にここと同じ除外実験をやること
    /// **2026-08-16 に乗換案内の2枚(赤羽→立川。半開き/展開)を足して 640 → 703 / 301 → 307**。
    /// 増分 **indexed +63 / unwritable +6** は**新しい2枚に完全に閉じている**
    /// (`ios-maps_transit_steps` 13/4 ・ `ios-maps_transit_steps_expanded` 50/2 = 総差分と一致)。
    /// **格付けは画面ごとに閉じている**(`SelectorNaming` は snapshot 1枚から作る)ので、
    /// 他の46枚は定義上不動 —— 除外実験は算術で足りる。
    ///
    /// 内訳は全部数え上げてある。**どちらも正しい格付け**:
    /// - 展開(indexed 50): 手順の行が**下位ビューごと同じ id で繰り返される**
    ///   (`#TextStackView`×8 / `#DetailButton`×9 / `#MainStackView`・`#CarStackView`・
    ///   `#TransitDirectionsBoardingInfoView` 等が各×2)。ラベルを持つものも「さらに表示」
    ///   「4駅（12分）」が行ごとに重複するので、素の `#id` でもラベルでも一意に選べない
    /// - 半開き(indexed 13): 大半が背後の地図 POI(`#VKPointFeature` 8。無名か地名の重複)
    /// - unwritable 6 のうち展開側の2件は**画面外の行**(中心 y=890 / 画面高 874)で、
    ///   クランプされた座標を持つため候補から外れる —— `ios-news_feed` と同じ理由で、
    ///   **スクロールして実位置が出れば書ける**
    ///
    /// **割合は動いていない**(索引 25.2% は上限 25.5‰ の内側・書けない側も同様) ——
    /// 絞り込みの退行ではなく、コーパスが「全行が id を共有する密なリスト」を含むようになっただけ
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
        // **2026-08-15 に J1順位表(両OS。gridWithoutHeaderNote の誤検知修正の witness 対)を
        // 足して 593→653 / 179→241**。増分は数え上げ済み(FT_SELECTOR_DURABILITY=1 の内訳):
        //   ・**and-browser_j1_standings: indexed +0 / unwritable +61**(id を持つのは120件中12件
        //     だけで、残りはラベルが表の中で大量に重複する — 順位・勝点等の数字が同じ値を
        //     何十行と共有し、id も一意ラベルも無いので indexed 化する足場(容器 #id)も無い)
        //   ・**ios-browser_j1_standings: indexed +60 / unwritable +1**(同じ表だが Safari 側は
        //     `#WebView` という一意な祖先があり、scoped index(`#容器 >> .type[n]`)で書ける)
        //   ・**2枚を外して再計測すると 593 / 179 に戻る**(既存フィクスチャは1件も動いていない)。
        //     上限を上げるときはこの確認まで通すこと —— 内訳だけでは、既存画面の退行が新画面の
        //     増分に紛れても気付けない
        // **2026-08-14 に `ios-news_feed`(実機 SmartNews)を足して 566 → 593 / 122 → 168**。
        // 増分は**この1枚に完全に閉じている**(indexed 27・unwritable 46 = 総差分と一致)。
        // 書けない 46 の内訳は全部数え上げてある:
        //   ・**クランプされた記事セル 39**(id もラベルも持つのに書けない)—— フィード先頭では
        //     画面外の行が容器の原点へ潰れるので、`candidates()` の `hasClampedCoordinates` が
        //     候補から外す。**これは正しい格付け** で、残すと「解決できたのに別の場所を叩く」
        //     沈黙の誤りになる(見出しが40字超なのでラベル形の代替も無い)。
        //     **スクロールして実位置が出れば `#id` で書ける** = 恒久的に指せないわけではない
        //   ・無ラベル無 id の button 2 + clickable 1(タブ帯の下位ビュー)
        //   ・重複 id の `#crui_more_options_button` 1(同画面に4つ)
        //   ・広告コピーの staticText 3(ラベルが広告間で重複)
        // 割合は **5.3% → 6.9%**。1枚で 46/120 が書けない盤面なので一段動くのは構造的
        // **2026-08-14 に `and-camera_canvas`(Android 実機のカメラ)を足して 168 → 179**。
        // 増分11の内訳は数え上げ済み: この木は **51 要素中 46 が id を持つ**行儀のよい木で、
        // id が無いのはモード名の `StaticText` 5件(Night Sight / Portrait / Camera / Video /
        // Modes)だけ。**同じラベルが `mode_switcher` のラベルとしても出る**ので一意に絞れず、
        // 容器 `#mode_switcher` を足場にした索引形しか書けない = **格付けとしては正しい**。
        // 残る増分はプレビューの重ね合わせ層(同一矩形・無ラベル)で、同じ理由で索引側へ落ちる
        // **2026-08-15 に `ios-browser_yahoo_top`(iOS Safari の Yahoo 天気トップ・要素上限で
        // 切り詰められた実ページ)を足して 640 / 237 → 640 / 301**。
        // **除外実験まで通してある**(このファイルの規律): この1枚を外すと 640 / 237 に戻り、
        // 他の 44 枚は1件も動かない = 増分はこの1枚に完全に閉じている。
        // なお 653 → 640 / 241 → 237 の目減りは同日の**長ラベルの `*断片*` セレクタ**追加による
        // 改善(索引形 13 件と書けない 4 件が stable へ移った)で、この枚とは無関係。
        //
        // 増分 **indexed +0 / unwritable +64** の内訳は全部数え上げてある(120 要素中 64):
        //   ・**無ラベル無 id の `link` 47**(地点セル・アイコン・日付セルを包む素のアンカー。
        //     HTML の入れ子リンクそのもので、ラベルも id も持たない)
        //   ・**ラベルはあるが全国で重複する `link` 16**(`0%` / `10%` / `20%` / `32/25` /
        //     `33/26` —— 同じ気温・降水確率が地点をまたいで何度も出る)
        //   ・無ラベルの `scrollView` 1
        // **indexed が1件も増えていないのが要点** —— 索引形は `#容器 >> .型[n]` なので
        // 一意な id を持つ祖先が要るが、この木は**その `#WebView` すら要素上限で落ちている**。
        // 切り詰めが「web だと分かる手掛かり」だけでなく「索引形の足場」まで奪う、という
        // 同じ自己言及の帰結(fixture のコメント参照)
        // 2026-09-05: and-e2e_input_keyboard_resized(自前 SUT・実機)を足して 703 → 712(+2)。
        // 増分は `#field_wrapped` の中の無 id `textField` / `clickable`(容器で包んだ入力欄の形
        // そのもの。iOS 版の sut-* にも同じ形がある)で、この1枚に閉じている
        XCTAssertLessThanOrEqual(indexed, 712, "索引セレクタが増えている(実測 712)")
        // **割合は千分率で見る**(2026-08-12 のレビュー指摘)。百分率の整数除算だと
        // 「4%以下」が実際には 4.99% まで通り、宣言した上限より1ポイント緩い砦になる
        // (実測 4.75% が「4」に切り捨てられて素通りしていた)
        XCTAssertLessThanOrEqual(indexed * 1000 / max(1, total), 255,
                                 "索引セレクタの割合が増えている(実測 25.2%)"
                                 + " —— 画面を足しただけでは上がらない指標なので、絞り込みの退行を疑う")
        XCTAssertLessThanOrEqual(unwritable, 310, "書けない要素が増えている(実測 307)")
        // **書けない側にも割合ゲートを置く**。絶対数だけだと、コーパスを
        // 広げるたびに上限を上げる儀式になる(索引側で既に踏んだ轍)。
        //
        // **上限 55‰ の根拠**: 絞り込みの退行ではなく、
        // **アプリ側が identifier を1つも公開しない画面**をコーパスへ入れたため
        // (`and-apps_list` = Android 設定の「すべてのアプリ」。40 要素すべて id 無し)。
        // 増分は **ちょうど9件**で、全部を数え上げてある:
        //   ・同一ラベル `"65.54 KB"` の staticText ×6(型でも解けない = 索引しか無いが、
        //     **id を持つ容器が1つも無いので scoped index も書けない**)
        //   ・アプリバーの無ラベル clickable ×3(ラベルも id も無い)
        // 行と内側テキストの重複(`clickable "設定"` / `staticText "設定"` など ×12 組)は
        // **型で解ける**ので書ける側に残っている = 絞り込み自体は効いている。
        // **次に上げたくなったら、まず増分を1件ずつ数えること** —— 数えられない増分は退行
        // **2026-08-15 に 90‰ → 106‰**(実測 10.5%)。上げた理由は上の除外実験のとおりで、
        // **id を1つも持たない web ページ**を切り詰められた状態で入れたため
        // (`and-apps_list` を入れたときと同型の理由で、絞り込みの退行ではない)
        XCTAssertLessThanOrEqual(unwritable * 1000 / max(1, total), 106,
                                 "書けない要素の割合が増えている(実測 10.5%)")
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

    /// **一本鎖でも「どちらを掴んでも同じ」が成り立たない形**(2026-08-14・実機 Android の
    /// YouTube で実測)。画面規模の再生面と、その中の小さなスキップボタンが同じラベルを名乗る。
    /// 前者は再生トグル・後者は広告スキップで**別の動作**なのに、一本鎖として曖昧警告から
    /// 除外されていた(`MCPServer.isSingleChain` の doc 参照)
    func testFullScreenSurfaceSharingALabelWithASmallButtonIsAmbiguous() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let surface = ElementInfo(ref: 1, type: "clickable", identifier: "player_overlays",
                                  label: "Skip", value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 136, width: 1080, height: 1683), depth: 2)
        let button = ElementInfo(ref: 2, type: "clickable", identifier: "skip_ad_button",
                                 label: "Skip", value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 888, y: 1555, width: 192, height: 132), depth: 3)
        let snap = SnapshotResponse(sessionBundleID: nil, screen: screen,
                                    elements: [surface, button], truncatedCount: 0)
        XCTAssertFalse(MCPServer.isSingleChain([surface, button], in: snap),
                       "画面規模の面と中の小さなボタンを『同じもの』として除外した")
    }

    /// 陰性対照3つ(どれか1つでも欠けるとコーパスで誤検知が出る。全数で測って決めた):
    /// 片方が非操作 / 中心が中に入る / 大きいほうが画面規模でない
    func testOrdinaryWrapperChainsStayExcluded() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        func snap(_ els: [ElementInfo]) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: els, truncatedCount: 0)
        }
        // ⑴ 中身が staticText(触れても祖先が受け取る)= 実アプリで最も多い形
        let row = ElementInfo(ref: 1, type: "clickable", identifier: "row", label: "設定",
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 1080, height: 2000), depth: 2)
        let text = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "設定",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 30, y: 20, width: 200, height: 60), depth: 3)
        XCTAssertTrue(MCPServer.isSingleChain([row, text], in: snap([row, text])))

        // ⑵ 大きいほうの中心が小さいほうの中に入る(撃つ場所が同じ)
        let outer = ElementInfo(ref: 3, type: "clickable", identifier: "outer", label: "A",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 1080, height: 2000), depth: 2)
        let inner = ElementInfo(ref: 4, type: "clickable", identifier: "inner", label: "A",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 400, y: 900, width: 300, height: 300), depth: 3)
        XCTAssertTrue(MCPServer.isSingleChain([outer, inner], in: snap([outer, inner])))

        // ⑶ 大きいほうが画面規模でない(入れ子リンク。and-browser_weektable の形)
        let link = ElementInfo(ref: 5, type: "link", identifier: nil, label: "tenki.jp",
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 400, height: 100), depth: 2)
        let sub = ElementInfo(ref: 6, type: "link", identifier: nil, label: "tenki.jp",
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 150, height: 100), depth: 3)
        // 中心 (200,50) は sub(0..150)の**外** —— こうしないと中心判定で除外されてしまい、
        // 画面規模の条件を1バイトも検証しないテストになる(2026-08-14 に変異が生き残って判明)
        XCTAssertTrue(MCPServer.isSingleChain([link, sub], in: snap([link, sub])))
    }
}
