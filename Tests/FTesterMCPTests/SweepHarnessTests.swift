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
@testable import ftester_mcp

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
        var description: String {
            "ghost=\(ghost) overlay=\(overlay) stacked=\(stacked) misses=\(misses)"
                + " disabled=\(disabled) offscreen=\(offscreen) warnedTappable=\(warnedTappable)"
                + " keyboard=\(keyboard) sliver=\(sliver) nested=\(nested)"
                + " scrolledOut=\(scrolledOut)"
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
        "and-place_expanded": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0, disabled: 0,
                                     warnedTappable: 3),
        "and-results": Counts(ghost: 0, overlay: 18, stacked: 0, misses: 2, disabled: 0,
                              warnedTappable: 2),
        // 2026-08-12 採取。**設定ツリー**(Android)。misses 1 は
        // `#homepage_app_bar_regular_phone_view`(非操作の器)の中心が中の `#search_bar` に乗る形 =
        // 既存の「見出し容器」と同型の受理済み。警告付きのタップ対象は0
        "and-settings_root": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                    offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                    nested: 0, scrolledOut: 0),
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
        // 兄弟重なりで、ios-maps_suggest_keyboard と同型の現状固定
        "ios-maps_suggest_guides": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 0, disabled: 0,
                                          offscreen: 0, warnedTappable: 3, keyboard: 0, sliver: 0,
                                          nested: 1, scrolledOut: 0),
        // 2026-08-08 採取。検索候補 + キーボード(keyboardFrame (0,583 402x233))。
        // keyboard 16 はキーボード下の候補行群(Simulator 上のプローブでタップが顔文字キーに化けた
        // witness と同じ画面・同じ形 = 真陽性)。overlay 11 は候補行の button ← MultiTextView
        // 兄弟重なり(iOS は z が無い既知の限界。and-results と同型の現状固定)
        "ios-maps_suggest_keyboard": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0,
                                            disabled: 0, offscreen: 1, warnedTappable: 9,
                                            keyboard: 16),
        // 2026-08-12 採取。**チャット + ソフトキーボード**(会話を開いて入力欄に焦点)。
        // 全項目0 —— キーボードは出ている(`keyboardFrame` (0,583 402x233))が、その下に
        // タップ対象が1つも無い画面なので `keyboard` も0になる。**「何も出ない実アプリの画面」の
        // 供給源として意味がある**(検知が常に何か出す装置になっていないことの陰性対照)
        "ios-messages_keyboard": Counts(),
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
        // 2026-08-12 採取。**設定ツリー**(iOS)。全項目0 —— ios-messages_keyboard と並ぶ陰性対照
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
        // ghost 2(ページ冒頭の button 2つ)も同じ被覆によるもの。
        // **この画面は「オーバーレイ配下を1件ずつしか言えない」ことの witness**でもある
        // (まとめて1行で言う要約は未実装。docs/mcp-audit-rounds.md の台帳を参照)
        "ios-browser_startpage": Counts(ghost: 2, overlay: 64, stacked: 0, misses: 0, disabled: 1,
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
        "and-browser_weektable": Counts(),
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
        "and-browser_weather_weekly": Counts(ghost: 1, overlay: 14, stacked: 0, misses: 0,
                                             disabled: 0, offscreen: 0, warnedTappable: 2,
                                             keyboard: 0, sliver: 0, nested: 0, scrolledOut: 0),
        // 2026-08-13 採取(監査ラウンド5・jma.go.jp)。missingPageContentNote /
        // duplicateRegionNote の witness 対(NoteCoverageTests.baseline 参照)。
        // **ios-browser_jma_hscroll の 33 件は全数検分済み**(2026-08-13)。監査24で web ページに
        // 出た「折り返す inline テキスト」型の誤検知は1件も無く、原因は2つだけ:
        // ⑴ **Safari の浮動下部バーが本文を実際に覆う**(15件。occluder は #CapsuleNavigationBar /
        //    #BackButton / #MoreMenuButton。ft_screenshot で実描画を確認)
        // ⑵ **この木が持つ前後コピーの重なりそのもの**(18件。旧コピー x=349 と実体 x=359 のような
        //    ずれた二重、および x=0 へクランプされたセル同士の積み上がり)。
        //    duplicateRegionNote が名指しするのと同じ欠陥を、幾何側から数えている
        // ghost=4 は ⚠️scroll-leftover の4行 / offscreen=5 は y<0 の行 /
        // disabled=1・warnedTappable=1 はどちらも履歴なしの「戻る」
        "and-browser_jma_notree": Counts(),
        "ios-browser_jma_hscroll": Counts(ghost: 4, overlay: 33, stacked: 0, misses: 0,
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
    ]

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/FTesterMCPTests/このファイル
            .deletingLastPathComponent()          // Tests/FTesterMCPTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    static func counts(_ snap: SnapshotResponse) -> Counts {
        let els = snap.elements
        let stacked = RefGuard.stackedRefs(els)
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
            let scrolledOut = !RefGuard.scrolledOutWarning(e, in: els).isEmpty
            if scrolledOut { c.scrolledOut += 1 }
            if RefGuard.interactiveTypes.contains(e.type),
               ghost || overlay || misses || stacked.contains(e.ref) || disabled || offscreen
                || nested || scrolledOut {
                c.warnedTappable += 1
            }
            if RefGuard.interactiveTypes.contains(e.type),
               RefGuard.keyboardWarning(e, keyboardFrame: snap.keyboardFrame) != nil {
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
        let dir = Self.fixtureDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files.count, Self.baselines.count,
                       "フィクスチャと基準値の数が合っていない: \(files)")
        for file in files {
            let name = String(file.dropLast(".json".count))
            guard let expected = Self.baselines[name] else {
                XCTFail("基準値が無いフィクスチャ: \(name)"); continue
            }
            let actual = Self.counts(try load(dir.appendingPathComponent(file)))
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
    /// **上限を上げずに画面ごとに免除する**(2026-08-12)。全体の上限を 63% まで上げると
    /// この砦は何も見なくなる。免除は**明細を1件ずつ検分した画面だけ**に、実測値ちょうどで置く
    /// (`>=` ではなく等号照合なので、減っても増えても落ちる = 追認装置にならない)。
    /// web ページは「画面の下 1/4 がブラウザ chrome と広告」「オーバーレイが背後の本文を
    /// 覆ったまま木に残る」が常態で、**画面が本当に大半塞がっている** —— 検知の質の問題ではない
    static let densityExemptions: [String: Int] = [
        // 内訳は baselines の当該コメント(広告帯・Safari ツールバー・HTML 入れ子リンク)
        "ios-browser_nationwide.json": 39,
        // 内訳は同上 + スタートページのカードが背後の WebView 本文を覆う
        "ios-browser_startpage.json": 63,
    ]

    func testWarningDensityStaysLow() throws {
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
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
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
            let c = Self.counts(snap)
            let name = String(file.dropLast(".json".count))
            emit("BASELINE \"\(name)\": Counts(ghost: \(c.ghost), overlay: \(c.overlay),"
                + " stacked: \(c.stacked), misses: \(c.misses), disabled: \(c.disabled),"
                + " offscreen: \(c.offscreen), warnedTappable: \(c.warnedTappable),"
                + " keyboard: \(c.keyboard), sliver: \(c.sliver), nested: \(c.nested),"
                + " scrolledOut: \(c.scrolledOut)),")
            let els = snap.elements
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
                   RefGuard.keyboardWarning(e, keyboardFrame: snap.keyboardFrame) != nil {
                    emit("   DETAIL \(name) keyboard \(who)")
                }
                if RefGuard.isClippedSliver(e, screen: snap.screen) {
                    let f = e.frame
                    emit("   DETAIL \(name) sliver   \(who) \(Int(f.width))x\(Int(f.height))")
                }
                if let nested = RefGuard.nestedActionCoveringCentre(e, in: els) {
                    emit("   DETAIL \(name) nested   \(who) ← \(RefGuard.describe(nested))")
                }
                if let scroller = RefGuard.outsideDeclaredScroller(e, in: els) {
                    emit("   DETAIL \(name) scrolled \(who) outside \(RefGuard.describe(scroller))")
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
