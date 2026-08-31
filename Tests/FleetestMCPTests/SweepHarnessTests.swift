// 実アプリのスナップショットへ検知を全数で当てる回帰ゲート。
//
// **自前の 4 SUT は遮蔽・積み重なり・中身外しの形を代表しない** —— 2026-08-07 の3ラウンドで、
// 誤検知も真陽性も実アプリでだけ出た(4 SUT では1件も出ない)。だからコーパスを
// Tests/Fixtures/RealAppSnapshots/ に固定して、件数を基準値と突き合わせる。
//
// **「増えていないこと」を見るのが目的**。新しい検知を足したときに、それが雑音になっていないかは
// 自分では分からない(2026-08-07 に4種足した)。基準値を上げるのは、増えた分を1件ずつ見て
// 真陽性だと確かめてからにすること —— 黙って上げると、この砦は現状の追認装置になる。
//
// 別のコーパスへ当てたいときは FT_SWEEP_DIR でディレクトリを差し替える(件数の照合はしない)。

import XCTest
import FTCore
import FTTestSupport
@testable import fleetest_mcp

final class SweepHarnessTests: XCTestCase {

    /// 1画面ぶんの検知件数
    struct Counts: Equatable, CustomStringConvertible {
        var ghost = 0, overlay = 0, stacked = 0, misses = 0, disabled = 0, offscreen = 0,
            warnedTappable = 0
        /// keyboard はソフトキーボードに中心を覆われたタップ対象(keyboardFrame を申告する
        /// 新ブリッジの木でだけ非 0 になり得る)。**画面の一時状態**であって要素の恒常的な
        /// 問題ではないので warnedTappable(雑音密度ゲート)には入れない
        var keyboard = 0
        /// sliver は容器の縁で細帯に切れたラベル付き要素(TapTargetGeometry.isClippedSliver)
        var sliver = 0
        /// nested は自分の子孫に中心を横取りされた**対話要素**
        /// (TapTargetGeometry.nestedActionCoveringCentre。2026-08-09 追加)
        var nested = 0
        /// scrolledOut は**申告された**スクロール容器の完全に外に居る要素
        /// (TapTargetGeometry.outsideDeclaredScroller。ghost の推測版では拾えない形)
        var scrolledOut = 0
        /// clippedByContainer は容器の縁で切り詰められたタップ対象
        /// (TapTargetGeometry.clippedAtContainerEdge。2026-08-31 追加。実測は同関数の doc)
        var clippedByContainer = 0
        var description: String {
            "ghost=\(ghost) overlay=\(overlay) stacked=\(stacked) misses=\(misses)"
                + " disabled=\(disabled) offscreen=\(offscreen) warnedTappable=\(warnedTappable)"
                + " keyboard=\(keyboard) sliver=\(sliver) nested=\(nested)"
                + " scrolledOut=\(scrolledOut) clippedByContainer=\(clippedByContainer)"
        }
    }

    /// 2026-08-07 時点の実測値。**すべて中身を確認済み**:
    /// - `overlay` は全画面シート・app bar・下部フッタが実際に覆っている真陽性
    /// - `misses` は中心が中身のどこにも乗らない容器(`#layers_fab_button` 等)
    /// - `disabled` は E2E-CMP の契約上「押しても何も起きない」2ボタンだけ
    /// - `ghost` と `stacked` は**全画面で 0**(2026-08-07 に誤検知を潰した結果)
    static let baselines: [String: Counts] = [
        // 経路プランナーの移動手段タブ(2026-08-08 採取・版53)。**選択中ノード保持の形**
        // (`other checked`・id もテキストも無い)を含む唯一のフィクスチャ。
        // **ただしこれは採取時点の木の凍結**であって、Java 側 shouldInclude の退行は
        // 落とせない(生きたガードには SUT 側に id 無し selected ウィジェットが要る。未実施)。
        // overlay 6 は全件検分済み: 5件はシートが地図 chrome(#mylocation_button 等)を覆う
        // 真陽性、残る1件(warnedTappable の1)は全画面の地図 clickable の中心に
        // 提案テキストが乗る形 = and-results の「スポンサー ← footer」と同じ受理済みの型
        "and-directions_tabs": Counts(ghost: 0, overlay: 6, stacked: 0, misses: 0, disabled: 0,
                                      offscreen: 0, warnedTappable: 1, keyboard: 0, sliver: 0),
        "and-home": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 2, disabled: 0,
                           warnedTappable: 0),
        // 2026-08-08 採取(キーボード/IME 遮蔽検知の導入時)。keyboard 2 は Gboard の
        // レイアウト選択シートに覆われた候補行で、Emulator 上のプローブで実際にタップが IME に
        // 化けた witness と同一要素 = 真陽性。overlay 1(compass ← 候補行)も描画どおり
        "and-maps_suggest_ime": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                       warnedTappable: 0, keyboard: 2),
        // 2026-08-12 採取(アーキタイプ拡張)。**キーパッド**(同じ形の 12 キー格子)。
        // nested 1 は真陽性: `#dialpad_view`(0,1220 1080x1141・clickable)の中心 (540,1790) が
        // その中の `#eight`(377,1779 324x168)の上にある = 容器を撃つと「8」が入る。
        // overlay 1(#fab_container ← #dialpad_call_buttons)は通話ボタン列が FAB の器を覆う実描画どおり。
        // disabled 1 は入力が空のときの Backspace(`#deleteButton`)= 真陽性。
        // **実アプリで初めて `disabled` が出た2枚のうちの1枚**(それまで供給源は自前 SUT だけ)
        "and-dialer_keypad": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 1,
                                    offscreen: 0, warnedTappable: 2, keyboard: 0, sliver: 0,
                                    nested: 1, scrolledOut: 0),
        "and-overflow": Counts(),
        "and-place": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 1, disabled: 0,
                            warnedTappable: 0),
        // clippedByContainer 1 は検分済みの真陽性(2026-08-31): #recycler_view 下端(y=2204)で最終行 clickable 「情報の修正を提案」(0,2156 1080x48) が他の行(126px)から 48px に切れている
        "and-place_expanded": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0, disabled: 0,
                                     warnedTappable: 3, clippedByContainer: 1),
        "and-results": Counts(ghost: 0, overlay: 18, stacked: 0, misses: 2, disabled: 0,
                              warnedTappable: 2),
        // 2026-08-12 採取。**設定ツリー**(Android)。misses 1 は
        // `#homepage_app_bar_regular_phone_view`(非操作の器)の中心が中の `#search_bar` に乗る形 =
        // 既存の「見出し容器」と同型の受理済み。警告付きのタップ対象は0。
        // clippedByContainer 1 は検分済みの真陽性(2026-08-31): `#recycler_view` (0,796 1080x1565)
        // の下端で最終行 `音とバイブレーション` (0,2221 1080x140) が他の行(231〜270)より低く
        // 縁に接している = 一覧の最後の行が本当に切れている形
        "and-settings_root": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                    offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                    nested: 0, scrolledOut: 0, clippedByContainer: 1),
        // nested 1 は検分済みの真陽性: `#PinnedItemSection`(横スクロールする clickable の帯)の
        // 中心は、その中の `#PinnedTile` の上にある。帯を撃つと1枚のタイルが開く
        "ios-home": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                           warnedTappable: 1, nested: 1),
        // 2026-08-12 採取。**ホイールピッカー**の witness(コーパス初)。Apple マップの
        // 経路オプション。`pickerWheel` 3本が入れ物の `datePicker` (41,246.7 320x216) を
        // 上下へ約38pt はみ出して申告する(y 209.2・高さ 291)形を含む。
        // **この修正の前は overlay 3**(3本のホイールが、その上のセグメンテッドコントロール
        // 「今すぐ出発 / 出発時刻 / 到着時刻」の中心をそれぞれ覆っていると報告)で、
        // 実際のタップは3つとも正常に通る = 純粋な誤検知だった(reportsContentExtent で解消)。
        // **修正前 overlay 10 / warnedTappable 7 → 修正後 4 / 4**。残る4件は全部
        // 「`Reset`(36,786 330x52)が料金セクションの行を覆う」形で、**スクリーンショットで
        // 実描画を確認済みの真陽性**(シート下端に貼り付く Reset が `交通系ICカード運賃` の
        // 行の上に重なって描かれている)。nested 1 も真陽性(セグメント行 clickable
        // (16,194 370x52) の中心 (201,220) が中の `出発時刻` (142,204 117x32) の上)。
        // disabled 1 は入力前で押せない「完了」
        "ios-maps_route_options": Counts(ghost: 0, overlay: 4, stacked: 0, misses: 0, disabled: 1,
                                         offscreen: 0, warnedTappable: 4, keyboard: 0, sliver: 0,
                                         nested: 1, scrolledOut: 0),
        // 2026-08-08 採取(v58 = 間引きの bulk 拡張後)。東京駅カード + 地図 POI 67個の木。
        // overlay 17 の内訳: POI 同士の重なり14(駅構内の高密度で実描画どおり・非操作)/
        // カード見出し系3。misses 2 は見出し容器。すべて非操作なので warnedTappable 0
        "ios-maps_station": Counts(ghost: 0, overlay: 17, stacked: 0, misses: 2, disabled: 0,
                                   warnedTappable: 0),
        // 2026-08-09 採取。**nested 検知の witness**: `#Maps.PlaceTableViewCell` (20,138 362x155) の
        // 中心 (201,215) が、同じセルの中の `#FeaturedInMultipleGuidesContextLineItem`
        // (80,202 205x18) の上にある。Simulator 上で ft_tap がガイド一覧を開いた実測の真陽性。
        // overlay 2(無名 button ← #RichTextLabel / #MultiTextView)は iOS に z が無いことによる
        // 兄弟重なりで、ios-maps_suggest_keyboard と同型の現状固定。
        // keyboard 0(2026-08-14・「chrome の部分木は覆われた側に数えない」修正で 2→0): この画面の
        // 唯一の候補は地球儀キー `次のキーボード`(ref33)・`#dictation`(ref34)で、どちらも
        // `#inputView`/`#SystemInputAssistantView` の子孫 = chrome 自身の一部。覆っている側を
        // 「覆われている」と数えていた雑音で、アプリ側の要素は元から0件のまま
        "ios-maps_suggest_guides": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 0, disabled: 0,
                                          offscreen: 0, warnedTappable: 3, keyboard: 0, sliver: 0,
                                          nested: 1, scrolledOut: 0),
        // 2026-08-08 採取。検索候補 + キーボード(keyboardFrame (0,583 402x233))。
        // keyboard は候補行群(Simulator 上のプローブでタップが顔文字キーに化けた witness と同じ画面・
        // 同じ形 = 真陽性)。overlay 11 は候補行の button ← MultiTextView 兄弟重なり
        // (iOS は z が無い既知の限界。and-results と同型の現状固定)。
        // **16→30→20**: 08-13 の「偽の全クリア」修正で申告のキー面だけでは拾えなかった3種が
        // 木の chrome で広がって入ったが、そのうち予測変換バー(7件)と地球儀キー・`#dictation`
        // (2件)は chrome 自身の部分木で、覆っている側を覆われていると数えた雑音だった
        // (2026-08-14 修正で 30→20 = -10)。残る20件は5件目の候補行
        // `#Maps.PlaceTableViewCell`(ref64、y=836)とその子(button/`#MultiTextView`/
        // `#IconImage`)を含む5行ぶん = 実際にキーボードの下に隠れた検索結果(修正が狙った実害そのもの)
        "ios-maps_suggest_keyboard": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0,
                                            disabled: 0, offscreen: 1, warnedTappable: 9,
                                            keyboard: 20),
        // 2026-08-16 採取(赤羽→立川の乗換案内)。**同じ画面の2状態**で、
        // 注記の量を測るための供給源(NoteCoverageTests の当該コメント参照)。
        //
        // scrolledOut 5(両状態とも)は**真陽性**: 容器 `#TransitDirectionsListView` より上へ
        // 出た「出発 / 赤羽駅」の行群(半開きでは y=554〜639 対 容器 y=640〜)。評価者が
        // 「scroll-leftover が多くノイズ」と言った当人で、印は行ごとに出続けるべき側。
        // misses(半開き2 / 展開4)は `#MainStackView` (64,272 322x55) の中心 y=299.5 が
        // 子と子の隙間(`#LabelAndButtonStackView` の下端 299 と `乗車位置` の上端 306)に
        // 落ちる形 = and-form_keyboard で受理済みの型。offscreen は画面高 874 に対し
        // 中心 y=877/890 の行(下端に半分隠れた停車駅)。
        //
        // **overlay は状態で意味が違う**:
        // - 半開き 1 =「閉じる」(336,648 42x42)が leftover 行の `#DetailButton`
        //   (350,640 29x29)の中心を覆う。浮いた閉じるボタンと行の chevron の実重なりで、
        //   撃ち分けが本当に曖昧 = 真陽性
        // - 展開 1 = `4:58`(351,510 34x19)が同じ行の `#DetailButton`(356,498 30x30)の
        //   中心に乗る形。**Simulator で実際に撃って裏取り済み** —— タップは chevron に通り、
        //   地図がその停車駅へ寄ってシートが半開きへ戻った = **装飾の staticText が
        //   操作可能要素の中心に重なる既知クラスの誤検知**(ios-safari_article 10件・
        //   and-browser_error_page 1件と同型)
        //
        // **展開側は整定を待ってから採ること**(2026-08-16 に踏んだ): ドラッグ直後に読むと
        // `#DetailButton` **だけ**が最終位置より 13〜30pt 下に居り(他の要素は最初から最終位置)、
        // その一過性の木では overlay が 4 件出る(うち3件は `#PrimaryAccessoryLabel` との
        // 重なり)。連続2回の読みが一致することを確かめてから保存した
        "ios-maps_transit_steps": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 2, disabled: 0,
                                         offscreen: 1, warnedTappable: 2, keyboard: 0, sliver: 0,
                                         nested: 0, scrolledOut: 5),
        "ios-maps_transit_steps_expanded": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 4,
                                                  disabled: 0, offscreen: 2, warnedTappable: 3,
                                                  keyboard: 0, sliver: 0, nested: 0, scrolledOut: 5),
        // 2026-08-12 採取。**チャット + ソフトキーボード**(会話を開いて入力欄に焦点)。
        // タップ対象が無い画面という点は変わらない ——「何も出ない実アプリの画面」の供給源
        // (検知が常に何か出す装置になっていないことの陰性対照)。
        // keyboard 0(2026-08-13 に 0→2、2026-08-14 に 2→0): 唯一の候補は地球儀キー・
        // `#dictation` で、ios-maps_suggest_guides と同型の chrome 自身の部分木。この画面固有の
        // アプリ要素は最初から0のまま(「何も出ない実アプリの画面」の供給源としての役割は不変)
        "ios-messages_keyboard": Counts(),
        // 2026-08-14 採取(**Android 実機**の Google カメラ)。**全画面キャンバス**(a11y がほぼ空の面)。
        // **この1枚が、同日入れたばかりの原点クランプ判定の誤検知を即座に捕まえた** ——
        // プレビューの重ね合わせ層 14 枚が全部 (0,288 1080x1440) に並ぶ普通の形なのに
        // stacked が 13 件付いた。矩形一致の側には最初からあった「無地のラッパーは数えない」
        // (中身を持つものが3個以上)を原点側に付け忘れていたため。条件を写して **13 → 0**、
        // 真陽性(ios-news_feed の 60)は不変。
        // overlay 31 は `#options_menu_container` (0,112 1080x1457) が重ね合わせ層の中心を
        // 覆う形で、器が層より後に来る木の順序どおり = 現状固定(タップ対象は0件なので
        // warnedTappable も0)。misses 1 は中心が中身に乗らない器 = 受理済みの型
        "and-camera_canvas": Counts(ghost: 0, overlay: 31, stacked: 0, misses: 1, disabled: 0,
                                    offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                    nested: 0, scrolledOut: 0),
        // 2026-08-14 採取(**iOS 実機**の SmartNews・フィード先頭)。**append-on-scroll の本物**で、
        // 実アプリ固有の形を2つ持ち込む —— ⑴ 行が画面幅いっぱい ⑵ 画面外の行 65 件が
        // 全部 (0,103) にクランプされて木に載る(120 件中)。件数の意味:
        // - **stacked 42**: クランプ 65 件のうち印が付く数。`stackedRefs` は**矩形の完全一致**が
        //   3個以上の群にだけ付けるので、原点は同じでも大きさが違う **23 件は無印**で残る。
        //   実機で無印の行を撃つと実際に別画面へ飛ぶ(カルーセルの販促カード)ことを確認済み。
        //   **広げる案は次の増設の回へ**(原点一致は容器と子で普通に起きるので、誤検知の実測が要る)
        // - **stacked 42 → 60**(2026-08-14・原点クランプへ拡張): `stackedRefs` が矩形の完全一致
        //   しか見ていなかったため、行の高さがまちまちな実アプリのフィードでは 65 件のクランプに
        //   42 件しか印が付かなかった。同じ原点に同 depth の兄弟が3つ以上 + 原点を貸す容器、
        //   という条件を足して +18(`OcclusionGeometry.originClampedRefs`)。
        //   **コーパス全数で誤検知0**を測ってから入れた —— 他の39枚は1件も増えていない
        // - **overlay 52 → 23 → 7**(2026-08-14 に修正・下記): 採取直後は無印の行の大半もこちらで
        //   警告されていたが、名指しする相手が**同じくクランプされた別の幽霊**だった
        //   (例: `staticText "髪型…" ← staticText "広告 …"`。塗り順の最前面を採る規則が、
        //   幽霊だらけの座標では機能しない形)。**修正**: `OcclusionGeometry.occluder` が
        //   `isOutsideContainer`(容器の**外**)しか見ておらず、容器の**原点にクランプ**された
        //   残骸(`hasClampedCoordinates` と同じ現象)を遮蔽候補から除けていなかった。
        //   同じ判定を足すと全数で **overlay 52→23・wrong_culprit 30→0**(コーパス全数の
        //   プローブで確認)。DSL の `occlusionAdvisory` も同じ関数を経由するので同時に直る。
        //   **原点クランプへ拡張した際に 23→7 へさらに落ちた** —— 印の規則だけ広げて遮蔽候補の
        //   除外を広げないと「印は付くのに犯人としては名指しされ続ける」食い違いが残るので、
        //   `occluder` にも同じ判定(isOriginClamped)を通した
        // - **overlay 7 → 6**(2026-08-14・「中身の有無」規則): 上部のチャンネルタブ(y=59..100)を
        //   `#crui_channelView_tableView` (0,0 393x769) が覆っていると報告していた。表はタブの
        //   **下**に敷かれているが iOS は z を出さないので木の順序で手前と判定される。
        //   **容器のその点に子孫が1つも無ければ何も隠していない**という条件で解消(表の最初の行は
        //   y=103)。容器そのものを弾く案は真陽性を落とすので採らない —— ios-browser_startpage の
        //   `StartPageCollectionView` は背後の本文リンクを実際に覆っており、そこには中身がある
        // - **残る overlay 6 は別種**(未修正・ブリッジの版上げが要るので保留): 犯人は
        //   `button (360,59 30x41)` = ラベル「垂直スクロールバー, 6ページ」の**スクロール指標**。
        //   「ガジェット」タブ (321,59 79x41) の中心 x=360.5 がその上に乗る。指標は通常
        //   タッチを取らないので誤検知だが、XCUITest の `scrollBar` 型がランナー側で `Button` に
        //   落ちており、型で見分けるにはブリッジの版上げ + 全台再構築が要る。
        //   **ラベル("垂直スクロールバー")での判定はしない** —— 言語に依存する
        // - **warnedTappable 14→13→12**: overlay 単独で警告されていた分が、他の advisory にも
        //   当たらず無警告に戻った(消えた警告は「誤って名指しされていた警告」なので後退ではない)
        // - misses 1 / nested 6: タブ帯とセルの中の帯 = 受理済みの型
        "ios-news_feed": Counts(ghost: 0, overlay: 6, stacked: 60, misses: 1, disabled: 0,
                                offscreen: 0, warnedTappable: 12, keyboard: 0, sliver: 0,
                                nested: 6, scrolledOut: 0),
        // 2026-08-12 採取。**メディアグリッド**(写真6枚のタイル)。misses 1 は
        // `#PXGGridLayout-Group`(非操作の器)の中心が中のタイルに乗る形 = 受理済みの型
        "ios-photos_grid": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                  offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                  nested: 0, scrolledOut: 0),
        "ios-place": Counts(ghost: 0, overlay: 3, stacked: 0, misses: 2, disabled: 0,
                            warnedTappable: 0),
        // 2026-08-09 採取。**scrolledOut 検知の witness**: 場所カードを送ると
        // `#MUScrollableStackView` (0,72 402x802) の上へ抜けたガイド欄が frame ごと木に残る。
        // scrolledOut 3 は容器3枚(`#CuratedGuidesSection` / `#MUCuratedGuidesSectionView` /
        // その collectionView)。中のセルは「自分の横カルーセルの中」に居るので印が付かず、
        // 代わりに offscreen(中心が画面の外)で拾われる —— 両者は排他ではなく、重い方を先に言う。
        // offscreen 13 と warnedTappable 6 は既存検知の素の結果で、全件が画面外の実座標
        "ios-place_guides_scrolled": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 3,
                                            disabled: 0, offscreen: 13, warnedTappable: 6,
                                            keyboard: 0, sliver: 0, nested: 0, scrolledOut: 3),
        "ios-profile": Counts(),
        // 2026-08-12 採取。**WebView / ブラウザ**(Safari で Wikipedia の記事)。
        // **14 件の overlay を全数検分した結果、10 件は誤検知・4 件は真陽性**:
        // - **誤検知 10 件は「折り返す inline テキスト」**という新しい下位形。web の a11y は
        //   1つの文中の run ごとに矩形を出すが、**折り返した run は前の run と同じ原点で
        //   2行ぶんの高さを持つ**(実測: staticText "A mobile app…"(16,332 254x23)と
        //   link "computer program"(16,332 328x51)は原点が一致し、後者が前者を完全に含む)。
        //   iOS は z を持たないので後着の link が「手前」と読まれるが、その座標に実際に
        //   描かれているのは前の run の字。**既知の「iOS に z が無い」型の一種**であって
        //   新しい欠陥ではないが、**1画面に 10 件出るのはこのコーパスで初めて**
        // - **真陽性 4 件**は下部ツールバー(`#MoreMenuButton` (90,792 48x48) /
        //   `#CapsuleNavigationBar`)がページ本文(y=823〜844 の "The"/"Instagram"/
        //   "photo sharing app on a")を覆う形。ここを撃つとブラウザの chrome に当たる
        // disabled 1 は履歴が無いときの「戻る」(`#BackButton`)= 真陽性。
        // warnedTappable 7 = 誤検知の link 5 + 真陽性の link "Instagram" 1 + disabled 1
        "ios-safari_article": Counts(ghost: 0, overlay: 14, stacked: 0, misses: 0, disabled: 1,
                                     offscreen: 0, warnedTappable: 7, keyboard: 0, sliver: 0,
                                     nested: 0, scrolledOut: 0),
        // 2026-08-12 採取。**設定ツリー**(iOS)。全項目0(キーボード非表示の画面での陰性対照)
        "ios-settings_root": Counts(),
        "sut-cmp_controls": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 2,
                                   warnedTappable: 2),
        "sut-cmp_home": Counts(),
        // sutec-* は sut-ec-mobile の **iOS in-app** の木(2026-08-08 の in-app 監査で採取。
        // それまで in-app の実樹はコーパスに1枚も無かった)。offscreen は全件確認済みの真陽性:
        // calendar_day の #slot_07 は Simulator 上で無反応タップを実測・#slot_23 とホームの
        // 「カテゴリ」は中心が幾何的に画面外。detail の overlay(説明文 ← #btn_add_to_cart)は
        // タップが実際にカート追加になった実測の真陽性。calendar_day の overlay
        // (#btn_back ← #slot_10)は**確認済みの誤検知**(Simulator 実測: btn_back の中心を
        // 叩くと正常に戻る。slot_08〜10 の frame はヘッダ裏の真っ白な領域を指しており、
        // そこには描かれていない。iOS は z が無く後着の行が「手前」と読まれる既知の限界)
        // —— 挙動の現状を固定する値であって真陽性の追認ではない
        "sutec-calendar_day": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                     offscreen: 2, warnedTappable: 3),
        "sutec-detail": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 1,
                               offscreen: 0, warnedTappable: 1),
        "sutec-home": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 0,
                             offscreen: 1, warnedTappable: 0),
        // 2026-08-12 採取。**ブラウザ**(実 web ページ + ブラウザ自身の操作面)。
        // 件数がコーパス中で突出して多いが、明細は全件検分済みで**発生源は3つだけ**:
        //   ①ページ内広告バナー(`【公式】…` / `23秒` の帯)が下の地図リンク群を覆う
        //   ②Safari の下部ツールバー(#TabBarItemTitle / #ReloadButton / #BackButton)が
        //     ページ末尾の行を覆う ③HTML の入れ子リンク(`<a>13<br>(木)</a>` の中の `<a>13</a>`)が
        //     外側の中心を横取りする = nested 13。いずれも実描画どおりで、撃てば内側/手前に当たる。
        // **web ページは「画面の下 1/4 がブラウザ chrome と広告」が常態**なので密度が高くなる
        // (testWarningDensityStaysLow の免除表を参照)
        "ios-browser_nationwide": Counts(ghost: 0, overlay: 22, stacked: 0, misses: 0, disabled: 0,
                                         offscreen: 3, warnedTappable: 35, keyboard: 0, sliver: 0,
                                         nested: 13, scrolledOut: 0),
        // 同上 + **スタートページのオーバーレイが背後の WebView 本文を覆う**形。
        // overlay 64 のうち 55 はカード群(#favoritesItemIdentifierContent 33 /
        // #resumeBrowsingItemIdentifierContent 9 / onboarding 6 / #reading-list 3 ほか)で、
        // **背後の要素は木に残ったまま**タップできない = 真陽性。keyboard 55 も同じ背後の本文。
        // **この画面は「オーバーレイ配下を1件ずつしか言えない」ことの witness**でもある
        // (まとめて1行で言う要約は未実装。docs/mcp-audit-rounds.md の台帳を参照)
        // 2026-08-23: ghost 2→0 / overlay 64→66。ページ冒頭の button 2つ(通知・メニュー)は
        // 旧の容器推定が `link (140,65 134x17)` を容器と取り違えて立てていた**誤検知**で、
        // 容器推定が scrollable 申告の祖先(scrollView)を優先するようになって消えた。
        // 同じ2件は被覆(overlay)として残る = 件数の移動であって検知の消失ではない
        "ios-browser_startpage": Counts(ghost: 0, overlay: 66, stacked: 0, misses: 0, disabled: 1,
                                        offscreen: 4, warnedTappable: 67, keyboard: 55, sliver: 0,
                                        nested: 13, scrolledOut: 0),
        // Android の web は検知がほとんど出ない(a11y 木が浅く、覆う要素が申告されない)。
        // overlay 1 = `button "さらに表示" ← link "13106"` は **確認済みの誤検知**:
        // スクリーンショットでは「さらに表示」の白いピルが手前に描かれているが、申告された
        // 塗り順は button z=21 / link z=60 で逆。Chrome の WebView が web の要素へ渡す z は
        // 描画順ではなく文書順に見える。**ios-safari_article の折り返し inline テキスト 10 件と
        // 同じ既知の型**(挙動の現状固定であって真陽性の追認ではない)
        "and-browser_weather": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                      offscreen: 0, warnedTappable: 1, keyboard: 0, sliver: 0,
                                      nested: 0, scrolledOut: 0),
        // overlay 1(clickable ← #omnibox_suggestions_dropdown)は真陽性 —— URL バーの
        // ポップアップが背後を覆う。**Android は背景を木から落とす**ので残骸が 1 件で済む
        // (iOS の ios-browser_startpage が 64 件出るのと対の陰性対照)
        "and-browser_urlmenu": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                      offscreen: 0, warnedTappable: 1, keyboard: 0, sliver: 0,
                                      nested: 0, scrolledOut: 0),
        // 2026-08-12 採取。gridWithoutHeaderNote / addressBarNote の witness 対(作業1〜3)。
        // Android 側は and-browser_weather と同型の浅い a11y 木で、全項目0
        // clippedByContainer 1 は検分済みの真陽性(2026-08-31): WebView 下端(y=2363)で地域 link 「小笠原村」(0,2302 241x61) が他の行(147px)から 61px に切れている
        "and-browser_weektable": Counts(clippedByContainer: 1),
        // 同じページを iOS Safari で採取した陰性対照(見出し行がツリーにある)。**全件検分済み**:
        // overlay 6 のうち4件(ref67/68/82/83「30/22」「10%」「29/24」「60%」 ← #MoreMenuButton /
        // #TabBarItemTitle / #CapsuleNavigationBar)は ios-safari_article と**同一の型**
        // (Safari 下部ツールバーがスクロール先の本文を覆う。あちらのコメント参照)。
        // 残り2件(ref19/20「Image for Taboola Advertising Unit」← ref21 の折り返した広告リンク)は
        // ios-safari_article の「折り返す inline テキスト」と同型(iOS に z が無い既知の限界)。
        // offscreen 4 は screen 高さ 874 を超えて報告される週間天気アイコン(y=862+31=893>874)= 真陽性。
        // disabled 1 は履歴が無いときの「戻る」(#BackButton)= ios-safari_article と同型の真陽性。
        // 新しい形は1件も無い(挙動の現状固定であって真陽性の追認ではない)
        "ios-browser_weektable": Counts(ghost: 0, overlay: 6, stacked: 0, misses: 0, disabled: 1,
                                        offscreen: 4, warnedTappable: 2, keyboard: 0, sliver: 0,
                                        nested: 0, scrolledOut: 0),
        // 2026-08-15 採取の1枚(iOS Safari・Yahoo 天気トップ)。**全件検分済み**。
        //
        // nested 20 は**全部真陽性**で1つの形 —— 日付セル `link "16 (日)"` と地点セルが
        // **入れ子のアンカー**を持ち、外側の中心が内側("16" / "28/22" 等)に乗る。ref で
        // 外側を撃つと内側が取る、という警告どおりの構造(HTML のリンク入れ子そのもの)。
        // overlay 5 は**全部 `link "東海北陸近畿"`(158,597 72x77)が発生源**で、地図の地方リンクが
        // 金沢・大阪のセルと矩形で重なる形。iOS の木に `z` が無いためツリー順に落ちた判定で、
        // 実描画ではセルが手前 = **既知クラスの誤検知**(ios-safari_article の「折り返す inline
        // テキスト」と同じ、z を持たない木の限界)。disabled 1 は履歴なしの「戻る」= 真陽性。
        // **新しい形は1件も無い**
        "ios-browser_yahoo_top": Counts(ghost: 0, overlay: 5, stacked: 0, misses: 0, disabled: 1,
                                        offscreen: 0, warnedTappable: 25, keyboard: 0, sliver: 0,
                                        nested: 20, scrolledOut: 0),
        // 2026-08-13 採取(Yahoo!天気の週間画面・同じ画面を両 OS で)。**全件検分済み**。
        //
        // iOS: overlay 30 は**全部真陽性**で、しかも1つの原因 —— 下端に貼り付く広告
        // (「【公式】ホットペッパーグルメ」)が週間表のアイコン・気温・降水確率の行を丸ごと覆い、
        // 「さらに表示」のピルが市区町村リンクを覆う。ft_screenshot で実描画を確認した
        // (広告の下に隠れて1つも見えない)。**覆われているのは staticText/image ばかり**なので
        // warnedTappable は 4 に留まる = 読み手には出ない: 「木に在るのに画面では読めない」
        // という形は、タップの安全性としては無害でも**裏取りの手段が無くなる**
        "ios-browser_weather_weekly": Counts(ghost: 0, overlay: 30, stacked: 0, misses: 0,
                                             disabled: 0, offscreen: 1, warnedTappable: 4,
                                             keyboard: 0, sliver: 0, nested: 0, scrolledOut: 0),
        // Android: **コーパスで初めて ghost が非0**(それまで全画面 0)。中身は
        // `staticText "洗濯指数10"` 1件で、ft_screenshot では同じ位置に下端の広告が描かれており
        // **その座標を叩けば広告に当たる** = 助言としては正しい。ただし「自分のスクロール容器の
        // 外」という理由付けのほうは depth から復元した親(直前の `link "8月14日(金)"`)に
        // 依るもので、a11y 上の本当の親ではない可能性が高い。**判定の当否ではなく助言の当否で
        // 真陽性とした**(同型が増えたら親の復元のほうを見直すこと)。
        // overlay 14 も同じ広告と「さらに表示」による被覆で、iOS 側と同じ原因
        // 2026-08-23: ghost 1→0 / overlay 14→15。上で「親の復元に依る」と注記していた ghost は、
        // 容器推定が scrollable 申告の祖先(WebView)を優先するようになって消えた(旧は
        // `Link (540,2184 517x97)` を容器と取り違えていた = 同型が増えたら見直す、と書いた当のもの)
        // 2026-08-28: ghost 0→1 / overlay 15→14 に**戻した**。申告の祖先を無条件で優先する規則が
        // iOS xcuitest の縦リストで容器を画面全体へ広げ、慣性で動いている最中に別の行を撃つ退行を
        // 入れていた(maintainer-notes §4.5.1)。申告へ倒すのを「候補が小さすぎるとき」だけに
        // 絞った結果、ここは 2026-08-23 以前の挙動へ戻る —— **上に書いてある取り違え
        // (`Link (540,2184 517x97)` を容器にする)がそのまま復活する**。
        // **意図した代償**: 位置を見る述語で退けようとしたが、動いている最中は行が容器の縁・外に
        // 報告されるため**効いてほしい瞬間だけ**申告容器へ倒れ、実機で2案とも落ちた。
        // スクロール探索が別の行を撃つ実害と、警告レベルの検知1件を秤にかけている
        "and-browser_weather_weekly": Counts(ghost: 1, overlay: 14, stacked: 0, misses: 0,
                                             disabled: 0, offscreen: 0, warnedTappable: 2,
                                             keyboard: 0, sliver: 0, nested: 0, scrolledOut: 0),
        // 2026-08-13 採取(jma.go.jp)。missingPageContentNote /
        // duplicateRegionNote の witness 対(NoteCoverageTests.baseline 参照)。
        // **ios-browser_jma_hscroll の 33 件は全数検分済み**(2026-08-13)。web ページで出る
        // 「折り返す inline テキスト」型の誤検知は1件も無く、原因は2つだけ:
        // ⑴ **Safari の浮動下部バーが本文を実際に覆う**(15件。occluder は #CapsuleNavigationBar /
        //    #BackButton / #MoreMenuButton。ft_screenshot で実描画を確認)
        // ⑵ **この木が持つ前後コピーの重なりそのもの**(18件。旧コピー x=349 と実体 x=359 のような
        //    ずれた二重、および x=0 へクランプされたセル同士の積み上がり)。
        //    duplicateRegionNote が名指しするのと同じ欠陥を、幾何側から数えている
        // offscreen=5 は y<0 の行 / disabled=1・warnedTappable=1 はどちらも履歴なしの「戻る」。
        // 2026-08-23: ghost 4→0 / overlay 33→37。旧の ghost=4(「scroll-leftover の4行」と読んでいた)は
        // 容器推定が行見出しの `staticText (0,627 27x19)` を容器と取り違えて、**画面内に描かれている
        // 表のセル**に立てていた誤検知。scrollable 申告の祖先(scrollView)を優先して消えた。
        // 4件は前後コピーの重なり(上の ⑵)として overlay に残る
        "and-browser_jma_notree": Counts(),
        // 2026-08-15 の監査(ブラウザ・格子)。Chrome の DNS エラーページ =
        // **ページが viewport に収まりきる**形(webViewGapNote の誤検知 witness。
        // TreeCoverage.pageExtendsBeyondViewport の陰性対照)。
        // overlay=1 は**既知クラスの誤検知**で、この修正とは無関係 —— ホスト名の span
        // `nonexistent.invalid` (63,900 312x47) が、それを含む文
        // ` にタイプミスがないか確認してください。` (63,900 955x110) に囲まれている
        // = ios-safari_article で 10 件受理済みの「折り返す inline テキスト」と同じ形
        "and-browser_error_page": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0,
                                         disabled: 0, offscreen: 0, warnedTappable: 0,
                                         keyboard: 0, sliver: 0, nested: 0, scrolledOut: 0),
        "ios-browser_jma_hscroll": Counts(ghost: 0, overlay: 37, stacked: 0, misses: 0,
                                          disabled: 1, offscreen: 5, warnedTappable: 1,
                                          keyboard: 0, sliver: 0, nested: 0, scrolledOut: 0),
        // 2026-08-13 の監査(長い再利用リスト)。Android 設定の「すべてのアプリ」——
        // **40 要素すべてが identifier を持たず、scrollable の申告も無い**平坦なリスト。
        // 幾何の検知はほぼ全部0 = **密なリストの陰性対照**として効く。
        // sliver=1 は `staticText "74.78 MB"` (y 2421・高さ3 / 画面高 2424)= 画面下端で
        // 切られた行の実測値で、**全数検分済みの真陽性**
        "and-apps_list": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 0,
                                offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 1,
                                nested: 0, scrolledOut: 0),
        // 2026-08-13 の監査(フォーム / ログイン)。Android 設定「ネットワークを追加」で
        // WPA を選び**キーボードが立ったまま**採った木。**保存/キャンセルがツリーに居ない**
        // (`#buttonPanel` が 1080x12 に潰れて中身を公開しなくなる)= フォーム特有の行き止まり。
        // misses=3 は全数検分済みの真陽性で、いずれも**容器の中心が子と子の隙間に落ちる**形:
        // `#type` の中心 y=739.5 は `#ssid`(〜734)と `#security`(809〜)の間、
        // 残る2件は `#collapsing_toolbar` / `#action_bar` の中心が空白域
        "and-form_keyboard": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 3, disabled: 0,
                                    offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                    nested: 0, scrolledOut: 0),
        // 2026-08-13 の監査(モーダル / ダイアログ)。Android 設定の確認ダイアログ。
        // **全項目0** —— 背景が a11y から落ちて木は6要素だけになり、幾何の検知は何も出ない。
        // 実アプリの**陰性対照**(検知が常に何か出す装置になっていないことの witness)
        "and-dialog_confirm": Counts(),
        // 2026-08-15 の監査(gridWithoutHeaderNote の誤検知)。J1順位表(jleague.jp)を両OSで採取
        // した対 —— `chainsHaveHeaderTopRow` を追加した witness そのもの(NoteCoverageTests /
        // GridWithoutHeaderNoteTests の当該コメント参照)。offscreen=1 は右にはみ出す
        // 競技切替タブ「ACL Two」・sliver=2 は下端で高さ6pxに切られたクラブ名行
        // clippedByContainer 1 は検分済みの真陽性(2026-08-31): WebView 下端(y=2363)で順位表の行 link 「清水エスパルス」(225,2357 213x6) が他の行(42px)から 6px に切れている
        "and-browser_j1_standings": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 0,
                                           offscreen: 1, warnedTappable: 1, keyboard: 0, sliver: 2,
                                           nested: 0, scrolledOut: 0, clippedByContainer: 1),
        // 同じページの iOS 側。overlay 5 は「清水エスパルス」行がページ先頭付近にあり、
        // z を持たない iOS の兄弟重なりで Safari の chrome(#BackButton・#MoreMenuButton・
        // #TabOverviewButton)に乗る形(ios-browser_nationwide 等と同型)。
        // offscreen 3 は右/下にはみ出す競技タブとクラブ行。disabled 1 は履歴なしの「戻る」
        "ios-browser_j1_standings": Counts(ghost: 0, overlay: 5, stacked: 0, misses: 0, disabled: 1,
                                           offscreen: 3, warnedTappable: 4, keyboard: 0, sliver: 0,
                                           nested: 0, scrolledOut: 0),
        // 2026-08-31 の実機監査(and-sutec_home)。**修正前の witness**: Android ブリッジが
        // 無ラベルの NavigationBar を間引き(SnapshotBuilder.shouldInclude)、preorder+depth の
        // 復元が下部タブ5本を `#screen_home`(scrollView)の子として再配線する形 ——
        // 修正前は5本とも `outsideDeclaredScroller` が容器の外と誤判定し scrolledOut=5(
        // かつ warnedTappable も clickable な4タブぶん押し上げていた)。
        // `StepExecutor.isChromePinnedOutside` の導入で scrolledOut は 0 に戻る
        // (ghost は元々0のまま不変 —— `RefGuard.isUntappableGhost` はタブの中心を覆う要素が
        // 無いため、容器外判定だけでは発火しない。DSL の再解決ループが空振りする実害は
        // `StepExecutor.isOutsideContainer` の生値を直接見ており、この Counts には出ない)。
        // misses=1 は無関係な既存の形(`#tab_home` が type=Other・唯一 label を持たず、
        // 子の "ホーム" ラベルが中心より下に来るため missesItsOwnContent が発火。他の4タブは
        // type=Clickable なので対象外)。sliver=3 は価格ラベル("¥18,000" 等)が高さ5pxで
        // 報告される形の真陽性(容器比ではなく寸法そのもの)。
        // 値は FT_SWEEP_BASELINE=1 で採取(2026-08-31)。修正前は scrolledOut=5(タブのラベル5件)+
        // ghost 側でタブ5件が「容器の外」だった = この画面が witness
        "and-sutec_home": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                  offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 3,
                                  nested: 0, scrolledOut: 0, clippedByContainer: 3),
    ]

    static func counts(_ snap: SnapshotResponse) -> Counts {
        let els = snap.elements
        let stacked = RefGuard.stackedRefs(els)
        // 申告 keyboardFrame はキー面だけ(KeyboardOcclusion の doc)。production
        // (MCPServer+Snapshot.swift)と同じ型で広げ、chrome 自身とその部分木を除外してから
        // 数える —— 生の申告のまま数えると、この砦がキーボード遮蔽の取りこぼしを永久に検出できない
        let keyboardOcclusion = KeyboardOcclusion.resolve(
            reported: snap.keyboardFrame, in: els)
        var c = Counts()
        for e in els {
            let ghost = RefGuard.isUntappableGhost(e, in: els, screen: snap.screen)
            let overlay = RefGuard.overlayCovering(e, in: els, screen: snap.screen) != nil
            let misses = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) != nil
            if ghost { c.ghost += 1 }
            if overlay { c.overlay += 1 }
            if stacked.contains(e.ref) { c.stacked += 1 }
            if misses { c.misses += 1 }
            // **production の関数を通す**: ここで `!e.enabled` を自前で見ると、
            // `RefGuard.disabledWarning` を壊してもこのゲートが落ちない(2026-08-07 の
            // 変異テストで実際に素通しした)。検知の回帰を見る砦なので必ず本番経路で数える
            let disabled = !RefGuard.disabledWarning(e).isEmpty
            if disabled { c.disabled += 1 }
            let offscreen = !RefGuard.offscreenWarning(e, screen: snap.screen).isEmpty
            if offscreen { c.offscreen += 1 }
            // **production の関数を通す**(disabled と同じ理由)。判定だけ自前で書くと、
            // 警告の組み立て側を壊してもこのゲートが落ちない
            let nested = RefGuard.nestedActionCoveringCentre(e, in: els) != nil
            if nested { c.nested += 1 }
            let scrolledOut = !RefGuard.scrolledOutWarning(e, in: els, screen: snap.screen).isEmpty
            if scrolledOut { c.scrolledOut += 1 }
            // **production の関数(TapTargetGeometry.advisoryKind)を通す**: 自前で
            // clippedAtContainerEdge を呼び直すと、その手前で勝つはずの強い判定
            // (zeroFrame〜stacked)を無視して二重計上する変異を見逃す
            if case .clippedByContainer = TapTargetGeometry.advisoryKind(
                for: e, in: els, screen: snap.screen) {
                c.clippedByContainer += 1
            }
            if RefGuard.interactiveTypes.contains(e.type),
               ghost || overlay || misses || stacked.contains(e.ref) || disabled || offscreen
                || nested || scrolledOut {
                c.warnedTappable += 1
            }
            if RefGuard.interactiveTypes.contains(e.type),
               RefGuard.keyboardWarning(e, keyboardOcclusion: keyboardOcclusion) != nil {
                c.keyboard += 1
            }
            if RefGuard.isClippedSliver(e, screen: snap.screen) { c.sliver += 1 }
        }
        return c
    }

    /// 採り直しの出力口。**`print` だけに頼らない** —— コーパスが 30 枚に増えたら
    /// XCTest の stdout 取り込みが**中央の連続する4枚ぶんを丸ごと落とした**(2026-08-12 に実測。
    /// 再実行しても同じ4枚が消える = 決定的)。基準値を上げる前の検分がこの出力に依存している
    /// ので、落ちると砦が黙って追認装置になる。`FT_SWEEP_OUT=<path>` を渡すとそこへ追記する
    private static let sweepOut = ProcessInfo.processInfo.environment["FT_SWEEP_OUT"]

    private func emit(_ line: String) {
        guard let path = Self.sweepOut else { return print(line) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func load(_ url: URL) throws -> SnapshotResponse {
        try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    /// 固定コーパスに対して件数が基準値どおりであること
    func testDetectionCountsMatchTheBaseline() throws {
        let corpus = try RealAppSnapshotCorpus.all()
        let files = corpus.map { $0.name + ".json" }
        XCTAssertEqual(files.count, Self.baselines.count,
                       "フィクスチャと基準値の数が合っていない: \(files)")
        for (name, snapshot) in corpus {
            guard let expected = Self.baselines[name] else {
                XCTFail("基準値が無いフィクスチャ: \(name)"); continue
            }
            let actual = Self.counts(snapshot)
            XCTAssertEqual(actual, expected,
                           "\(name) の検知件数が変わった。**増えた分を1件ずつ見て真陽性だと"
                           + "確かめてから**基準値を更新すること(\(actual) vs \(expected))")
        }
    }

    /// **雑音になっていないこと**: タップ対象のうち警告が付く割合の上限。
    /// 2026-08-07 の実測は実アプリで 0〜10%、自前 SUT の controls 画面だけ 18%
    /// (契約上の無効ボタン2つ = 真陽性)。
    ///
    /// **上限を 30% にしたのは 2026-08-09**: `ios-place_guides_scrolled` は
    /// タップ対象 21 のうち 6 = 28%。内訳はガイドのカルーセル(セル3 + その見出し3)が
    /// **丸ごとカードの上へ送り出された**もので、6件とも中心が画面外の実座標 = 真陽性。
    /// 「一画面の三分の一がスクロールで視界の外」という正当な状態が 20% を超えるので、
    /// **検知の質ではなく画面の状態**で落ちていた。件数そのものの砦は
    /// testDetectionCountsMatchTheBaseline 側で、こちらは粗い臭い取りに留める
    /// **上限を上げずに画面ごとに免除する**。全体の上限を 63% まで上げると
    /// この砦は何も見なくなる。免除は**明細を1件ずつ検分した画面だけ**に、実測値ちょうどで置く
    /// (`>=` ではなく等号照合なので、減っても増えても落ちる = 追認装置にならない)。
    /// web ページは「画面の下 1/4 がブラウザ chrome と広告」「オーバーレイが背後の本文を
    /// 覆ったまま木に残る」が常態で、**画面が本当に大半塞がっている** —— 検知の質の問題ではない
    static let densityExemptions: [String: Int] = [
        // 内訳は baselines の当該コメント(広告帯・Safari ツールバー・HTML 入れ子リンク)
        "ios-browser_nationwide.json": 39,
        // 内訳は同上 + スタートページのカードが背後の WebView 本文を覆う
        "ios-browser_startpage.json": 63,
        // **分母が6しかない画面**。半開きシートの経路詳細はタップ対象が
        // `#DetailButton`×3・「閉じる」・「さらに表示」・グラバーの6個だけで、警告2件で 33% に
        // 乗る。2件とも検分済みの真陽性(容器の外へ出た leftover の `#DetailButton` と、
        // 浮いている「閉じる」に中心を覆われた `#DetailButton`。内訳は baselines の当該コメント)
        // = **密度の高さは検知の質ではなく分母の小ささ**。展開側は分母14・警告3で 21% なので免除不要
        "ios-maps_transit_steps.json": 33,
    ]

    func testWarningDensityStaysLow() throws {
        for (name, snap) in try RealAppSnapshotCorpus.all() {
            let file = name + ".json"
            let tappable = snap.elements.filter { RefGuard.interactiveTypes.contains($0.type) }
            guard !tappable.isEmpty else { continue }
            let warned = Self.counts(snap).warnedTappable
            let percent = warned * 100 / tappable.count
            if let exempt = Self.densityExemptions[file] {
                XCTAssertEqual(percent, exempt,
                               "\(file): 免除した画面の密度が動いた(免除は検分済みの実測値ちょうど"
                               + "で置いてある)。明細を採り直して検分し直すこと")
                continue
            }
            XCTAssertLessThanOrEqual(percent, 30,
                                     "\(file): タップ対象の \(percent)% に警告が付いている"
                                     + " —— 検知ではなく雑音になっていないか見ること")
        }
    }

    /// 基準値の採り直し用(FT_SWEEP_BASELINE=1 のときだけ動く)。**貼り付け用の1行と、
    /// 何が発火したかの明細を両方出す** —— 基準値を上げる前に1件ずつ真陽性を確かめるため
    func testPrintBaselines() throws {
        guard ProcessInfo.processInfo.environment["FT_SWEEP_BASELINE"] == "1" else { return }
        for (name, snap) in try RealAppSnapshotCorpus.all() {
            let c = Self.counts(snap)
            emit("BASELINE \"\(name)\": Counts(ghost: \(c.ghost), overlay: \(c.overlay),"
                + " stacked: \(c.stacked), misses: \(c.misses), disabled: \(c.disabled),"
                + " offscreen: \(c.offscreen), warnedTappable: \(c.warnedTappable),"
                + " keyboard: \(c.keyboard), sliver: \(c.sliver), nested: \(c.nested),"
                + " scrolledOut: \(c.scrolledOut), clippedByContainer: \(c.clippedByContainer)),")
            let els = snap.elements
            let keyboardOcclusion = KeyboardOcclusion.resolve(
                reported: snap.keyboardFrame, in: els)
            for e in els {
                let who = RefGuard.describe(e)
                if let hit = RefGuard.overlayCovering(e, in: els, screen: snap.screen) {
                    emit("   DETAIL \(name) overlay  \(who) ← \(RefGuard.describe(hit))")
                }
                if let inner = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) {
                    emit("   DETAIL \(name) misses   \(who) → \(RefGuard.describe(inner))")
                }
                if RefGuard.isUntappableGhost(e, in: els, screen: snap.screen) {
                    emit("   DETAIL \(name) ghost    \(who)")
                }
                if !RefGuard.offscreenWarning(e, screen: snap.screen).isEmpty {
                    let f = e.frame
                    emit("   DETAIL \(name) offscreen \(who) centre=(\(Int(f.x + f.width / 2)),"
                        + "\(Int(f.y + f.height / 2)))")
                }
                if RefGuard.interactiveTypes.contains(e.type),
                   RefGuard.keyboardWarning(e, keyboardOcclusion: keyboardOcclusion) != nil {
                    emit("   DETAIL \(name) keyboard \(who)")
                }
                if RefGuard.isClippedSliver(e, screen: snap.screen) {
                    let f = e.frame
                    emit("   DETAIL \(name) sliver   \(who) \(Int(f.width))x\(Int(f.height))")
                }
                if let nested = RefGuard.nestedActionCoveringCentre(e, in: els) {
                    emit("   DETAIL \(name) nested   \(who) ← \(RefGuard.describe(nested))")
                }
                if let scroller = RefGuard.outsideDeclaredScroller(e, in: els, screen: snap.screen) {
                    emit("   DETAIL \(name) scrolled \(who) outside \(RefGuard.describe(scroller))")
                }
                if case .clippedByContainer(let container) = TapTargetGeometry.advisoryKind(
                    for: e, in: els, screen: snap.screen) {
                    let f = e.frame
                    emit("   DETAIL \(name) clipped  \(who) \(Int(f.width))x\(Int(f.height))"
                        + " in \(RefGuard.describe(container))")
                }
            }
        }
    }

    /// 別コーパスを当てるときの口(件数の照合はしない。FT_SWEEP_DIR を渡したときだけ動く)

    func testSweepExternalCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["FT_SWEEP_DIR"] else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(URL(fileURLWithPath: dir).appendingPathComponent(file))
            print("SWEEP \(file) elements=\(snap.elements.count) \(Self.counts(snap))")
        }
    }
}
