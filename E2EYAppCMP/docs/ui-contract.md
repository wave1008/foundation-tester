# FT E2EY アプリ UI 契約(全 E2EY SUT 共通)

**E2EY は「実アプリで頻出し、ツールの判定(容器の推定・端の判定・待ち・遮蔽・入力の読み返し)を
直撃する画面の作り」を並べた SUT**。E2EX(各フレームワークの定番部品)とは別のアプリで、共通契約も別
(この文書が全 E2EY SUT の唯一の正)。どの画面も GitHub の公開アプリで実際に使われている作りから
採った(出典は各節の「実例」)。

- この文書が全 SUT の画面・`#id`・ラベル・echo の正。**フレームワーク固有の実装選択・逸脱は各 SUT の
  `docs/ui-contract.md`**(CMP はこの文書の末尾「CMP の実装」)
- bundle ID / applicationId: CMP `com.ftester.e2ey` / Flutter `com.ftester.e2ey.flutter` /
  RN `com.ftester.e2ey.rn` / Android `com.ftester.e2ey.android` / iOS `com.ftester.e2ey.ios`
- 表示名: `FT E2EY`(SUT ごとに ` Flutter` 等を付ける)・ディープリンクは持たない
- シナリオ: `TestProjects/E2EY-<SUT>/scenarios/`・回すのは `Scripts/e2ey.sh`

## 全体規約(E2EX と同じ)

- すべての操作結果は画面上の **echo テキスト**に ASCII の決定的な文字列で出す。シナリオはこの文字列で
  成否を確かめる(部品の内部状態を a11y で読めるとは仮定しない)
- **echo は画面上部の固定領域(スクロールしない・キーボードやシートに隠れない・隠れるバーと一緒に
  隠れない位置)にまとめる**
- `#id`(testTag / accessibilityIdentifier / resource-id / testID)は付けられる所には全部付ける。
  **付けられない部品の内部はラベルで指す前提**(それ自体が検証対象)。付けられなかった `#id` は
  SUT の契約に理由付きで書く
- Android(Compose): ルートで `testTagsAsResourceId = true`。別ウィンドウ(Dialog・Popup・
  ModalBottomSheet)の中のルートにも付け直す
- 状態は画面離脱で初期化してよい(永続化しない)。**乱数・現在時刻を使わない**(遅延は固定秒)
- 最小サポート画面(iPhone SE 相当・Pixel 4a)で、各画面の「echo」と「最初に操作する要素」が
  同時に木に載ること
- **ツールの都合に合わせて作りを崩さない**。各画面の「罠」に書いた性質(木の順が逆・読み込み中も同じ
  ラベル 等)は**意図して残すもの**で、SUT 側で回避しない(回避するとその画面の存在意義が消える)

## シェル

- 画面上部に共通のトップバー: `#txt_screen_title`(各画面の見出し)・`#btn_back`(アイコンだけ・
  説明 `戻る`。ホームでは出さない)。システムの戻る(Android の戻る・iOS のエッジスワイプ)は
  各フレームワークの既定動作(A8 の画面だけは横取りする)

## ホーム(タイトル `E2EY ホーム`)

縦の一覧(行全体が押せる)。12 行なので小さい画面では下の行が折り返しの下に来る
(シナリオは `tap(..., scroll: .down)` で届かせる)。

| `#id` | 見出し(= 遷移先の画面タイトル) | 節 |
|---|---|---|
| `#nav_nested` | 入れ子スクロール | A1 |
| `#nav_chat` | 反転チャット | A2 |
| `#nav_loading` | 読み込みの状態 | A3 |
| `#nav_swipe_actions` | スワイプの操作 | A4 |
| `#nav_select` | 選択モード | A5 |
| `#nav_links` | 文中リンク | A6 |
| `#nav_pin` | PIN と OTP | A7 |
| `#nav_back_guard` | 戻るの横取り | A8 |
| `#nav_player` | 引き伸ばせるシート | A9 |
| `#nav_hide_bars` | スクロールで隠れるバー | A10 |
| `#nav_tab_header` | 折りたたみヘッダとタブ | A11 |
| `#nav_staggered` | 高さの揃わないグリッド | A12 |

## A1 入れ子スクロール(タイトル `入れ子スクロール`)

実例: compose-samples(Jetsnack・Jetcaster)・Element-X・IceCubes の投稿の行・firefox-ios のホーム。

- 縦の一覧 `#list_nested` に「棚」が 10 段。段 i(0〜9)は見出し `#txt_shelf_i` = `棚 i` と、
  **横に送れる一覧** `#shelf_i`(カード 15 枚)からなる
- カード `#card_i_jj`(jj = 00〜14)= `カード i-jj`。幅 140dp/pt・高さ 120dp/pt(1段に約 2.5 枚見える)。
  押すと `#txt_nested_result` = `nested=card_7_12`(初期 `nested=none`)
- 縦の一覧の全高は画面の 2 倍以上(段 7 以降は折り返しの下)
- **罠**: スクロールできる容器が2重(縦の中に横)。横の一覧の画面外のカードは木に居ない(仮想化)か
  画面外の座標で居る。縦の探索だけでは届かず、行(`#shelf_7`)を `scrollFrame` に指す必要がある
- 実装の例: Compose `LazyColumn` + `LazyRow` / Flutter `ListView` + 横の `ListView` /
  RN `FlatList` + `FlatList horizontal` / Android `RecyclerView` + 横の `RecyclerView` /
  iOS `List`(または `ScrollView` + `LazyVStack`)+ `ScrollView(.horizontal)` + `LazyHStack`

## A2 反転チャット(タイトル `反転チャット`)

実例: Element-X(iOS は `UITableView` を `scaleY: -1` で反転)・Signal・Mattermost・Rocket.Chat。

- 上部の固定領域: `#txt_chat_result` = `chat=msg_12`(押したメッセージ。初期 `chat=none`)/
  `#txt_chat_count` = `count=60`(件数)/ `#txt_chat_pos` = `at_bottom=true|false`(最新が見えているか。
  スクロールが止まった時点の値)/ `#btn_incoming` = `着信`
- 一覧 `#list_chat` は**反転したリスト**(新しいものが下・最初は最下部 = 最新が見えている)。
  メッセージ `#msg_00` … `#msg_59` = `メッセージ 00` …(00 が最古)。行の高さは揃える(56dp/pt 程度)
- メッセージを押すと `chat=msg_NN`
- `#btn_jump_bottom` = `最新へ`: 最下部から離れている間だけ一覧の右下に浮かぶ。押すと最下部へ送る
  (アニメーションあり)→ `at_bottom=true`
- 下端の入力バー: `#field_chat`(プレースホルダ `メッセージを入力`)・`#btn_send` = `送信`。送ると
  `#msg_60` …(本文 = 入力した文字列)を最下部に足し、最下部へ送り、欄を空にする
- `#btn_incoming`: 押して **1.0 秒後**に相手からのメッセージ `#msg_NN` = `着信 NN` を足す。
  **最下部に居れば追従して見せる・離れていれば位置を保つ**(`最新へ` が出たまま)
- **罠**: 木の並び順と見た目の上下が逆(実装による)。「上へ送る」= 過去へ。最初から最下部に居るので
  「下端」が始点。iOS の反転 `UITableView` は座標変換が transform に乗る
- 実装の例: Compose `LazyColumn(reverseLayout = true)` / Flutter `ListView(reverse: true)` /
  RN `FlatList inverted` / Android `RecyclerView` + `LinearLayoutManager(reverseLayout = true)` /
  iOS `UITableView` の `transform = CGAffineTransform(scaleX: 1, y: -1)`(セルも反転し直す)。
  **iOS SUT は入力バーを `inputAccessoryView` に載せる**(Signal の会話画面と同じ。キーボード側の
  別ウィンドウに居る入力欄の witness)

## A3 読み込みの状態(タイトル `読み込みの状態`)

実例: Paging3 の LoadState(Tusky・tivi)・`.redacted(reason: .placeholder)`(IceCubes)・
Skeletonizer(spotube)・シマー(Wikipedia)。

- 上部の固定領域: `#txt_loading_state` = `state=loading|loaded|error|end` /
  `#txt_loading_count` = `loaded=30` / `#txt_loading_result` = `loading=row_l_12`(初期 `loading=none`)/
  `#btn_reload` = `読み込み直す`
- 画面に入った直後と `読み込み直す` の直後は **2.0 秒**「読み込み中」(`state=loading`)。その間は
  **骨組みの行**を 8 行出す
- **骨組みの行は本物と同じ `#id`・同じラベル**(`#row_l_00` = `記事 00` …)を持ち、**押せない**
  (無効 = enabled=false。押しても何も起きない)。見た目は灰色の帯(シマーのアニメーション付きでよい)
- 2.0 秒後に本物の行 `#row_l_00` … `#row_l_29` = `記事 00` …(`state=loaded`・`loaded=30`)。
  本物の行を押すと `loading=row_l_NN`
- 末尾まで送ると、末尾に `#txt_footer_loading` = `読み込み中`(1.0 秒)→ **1回目は必ず失敗**して
  末尾に `#txt_footer_error` = `読み込みに失敗しました` と `#btn_retry` = `再試行`(`state=error`)
- `再試行` を押すと `読み込み中`(1.0 秒)→ `#row_l_30` … `#row_l_49` を足す(`loaded=50`・`state=loaded`)。
  さらに末尾まで送ると `#txt_footer_end` = `これ以上ありません`(`state=end`。それ以上は読まない)
- `読み込み直す` は 30 行・失敗1回の状態から始め直す
- **罠**: 読み込み中も同じ `#id`・ラベルが木に居る(出現待ちが早合点で通る。押せるまで待つ必要がある)。
  末尾の一時的な行(読み込み中・エラー)で「末尾に着いた」を誤判定しうる

## A4 スワイプの操作(タイトル `スワイプの操作`)

実例: IceCubes(`.swipeActions` の leading・full swipe)・NetNewsWire(UIKit の swipe provider)・
AppFlowy(flutter_slidable)・Signal / Element-X(スワイプで返信)。

- 上部の固定領域: `#txt_swipe_actions_result` = `action=row3:archive`(初期 `action=none`)/
  `#txt_swipe_actions_count` = `rows=6` / `#txt_reply_target` = `reply=none`
- 行 `#sw_row_1` … `#sw_row_6` = `スワイプ行 1` …(行を押すと `action=row3:open`)
- **右から左へ途中まで**払うと、行の右側に `アーカイブ`(`#btn_sw_archive_N`)と `削除`(`#btn_sw_delete_N`)が
  出たまま止まる。`アーカイブ` → `action=rowN:archive`(行は閉じる)/ `削除` → `action=rowN:delete`
  (行が消え `rows=5`)
- **右から左へ行幅の大半(定番の閾値を越える)まで**払うと、ボタンを押さずに削除まで走る(full swipe)→
  `action=rowN:delete`
- **左から右へ途中まで**払うと、行の左側に `ピン留め`(`#btn_sw_pin_N`)→ `action=rowN:pin`
- ボタンが出た行は、行の本体を押すか逆向きに払うと閉じる(`action` は変えない)
- その下に返信用の行 `#reply_row_1` … `#reply_row_3` = `返信行 1` …: **左から右へ閾値(行幅の約 25%)を
  越えて離す**と、行は元の位置へ戻り `reply=reply_row_2`(消えない・ボタンも出ない)
- **罠**: 払う距離で結果が変わる(ボタンを出す / 即削除)。ボタンは払うまで木に居ない(または幅 0)。
  in-app は慣性を持たないので、エンジンで結果が割れうる
- 実装の例: iOS `.swipeActions(edge:allowsFullSwipe:)` / Flutter `flutter_slidable` /
  Compose `AnchoredDraggable`(定番コンポーネント無し = 自前)/ RN gesture-handler の `Swipeable` /
  Android `ItemTouchHelper` か自前の reveal レイアウト。返信は各フレームワークのドラッグ検出の自前実装

## A5 選択モード(タイトル `選択モード`)

実例: Thunderbird・AntennaPod(`ActionMode`)・Signal-iOS(`allowsMultipleSelectionDuringEditing`)・
DDG のタブ一覧。

- 上部の固定領域: `#txt_select_mode` = `mode=normal|select` / `#txt_select_count` = `selected=0` /
  `#txt_select_result` = `select=none`
- 行 `#sel_row_01` … `#sel_row_20` = `項目 01` …
- 通常モード: 行を押すと `select=open:sel_row_05`
- **行を長押し**すると選択モードに入り、その行が選択される(`mode=select`・`selected=1`)。
  `#btn_edit` = `編集` を押しても入る(このときは何も選ばれていない)。選択モードの間 `#btn_edit` の
  ラベルは `完了`(同じ `#id` のままラベルが変わる。押すと抜ける)
- 選択モードでは行を押すと選択が切り替わる(開かない)。**選択状態は各フレームワークの標準の
  選択状態として公開する**(Compose `Modifier.toggleable` / `selectable`・iOS の選択・Android の
  `isActivated`/`isChecked`・Flutter `Semantics(checked:)`/`selected`・RN `accessibilityState`)。
  行頭にチェックの印を出す
- 選択モードの間、画面上部のバー(固定領域の下)が**アクションバーに置き換わる**:
  `#btn_sel_all` = `すべて選択` / `#btn_sel_delete` = `削除` / `#btn_sel_cancel`(アイコンだけ・説明 `キャンセル`)
- `削除` → 選んだ行を消して通常モードへ(`select=deleted:03,05`。番号の昇順・カンマ区切り)/
  `すべて選択` → `selected=<残りの行数>` / `キャンセル` か `完了` → 選択を捨てて通常モードへ
- **罠**: 同じタップの意味がモードで変わる。選択状態の読み方が Toggle と別。ラベルが変わる同一 `#id`

## A6 文中リンク(タイトル `文中リンク`)

実例: LinkAnnotation(Signal)・ClickableSpan(Tusky・Wikipedia)・TextSpan + TapGestureRecognizer
(AppFlowy の利用規約)・RN の入れ子 Text(Bluesky の RichText)。

- 上部の固定領域: `#txt_links_result` = `link=none`
- 段落 `#txt_terms` = `続行すると利用規約とプライバシーポリシーに同意したものとみなされます。`
  (**1つの文**。`利用規約` と `プライバシーポリシー` の部分だけがリンク)→ `link=terms` / `link=privacy`
- 段落 `#txt_post` = `@alice さんが https://example.com/a を共有しました`。`@alice` → `link=mention:alice`、
  URL → `link=url`(**外部へ遷移しない**。アプリ内で echo するだけ)
- 行全体が押せる行 `#row_with_link` = `お知らせ: 詳細はこちら`。行の本体 → `link=row`、
  文中の `こちら` だけ → `link=inner`(**入れ子のタップ対象**)
- リンク以外の部分を押しても何も起きない
- 文は**折り返さない幅**に収める(最小サポート画面で 1〜2 行。リンクが行を跨がないように)
- **罠**: 1つのノードの中に複数のタップ対象。リンクが子ノードとして出るかはフレームワークと版次第。
  文の中心を押すとリンクでない場所に当たる

## A7 PIN と OTP(タイトル `PIN と OTP`)

実例: Element-X の `PinEntryTextField` と自前キーパッド・Bitwarden の二段階認証・Pinput(immich・ente)。

- 上部の固定領域: `#txt_otp_result` = `otp=none` / `#txt_pin_result` = `pin=none` / `#txt_pin_len` = `pin_len=0`
- **OTP**: 6 桁。見た目は 6 つの箱 `#otp_box_1` … `#otp_box_6`(入力した数字を表示。伏せない)だが、
  **実体は隠れた入力欄 1 つ** `#field_otp`(数字キーボード)。箱のどれを押しても欄に焦点が移る
- 6 桁そろうと **0.3 秒後に自動で送信** → `otp=123456`(入力した数字列)、箱を空に戻す
- **PIN**: 4 桁。表示 `#pin_dots`(入力した桁数だけ `●`)。**ソフトキーボードを使わない自前のキーパッド**:
  `#key_0` … `#key_9`(ラベルは数字)・`#key_del`(アイコンだけ・説明 `削除`)
- 押すたびに `pin_len=N`。4 桁目で `pin=1234`(押した数字列)にして表示を空に戻す
- **罠**: 箱は入力欄ではない(打ち込む先は見えない欄)。送信が速く、読み返す前に値が消える。
  キーパッドは「文字を打つ」経路では入らない

## A8 戻るの横取り(タイトル `戻るの横取り`)

実例: Element-X / Signal の `BackHandler`・JetLagged の `PredictiveBackHandler`・AppFlowy の `PopScope`。

- この画面: `#txt_back_result` = `back=none` / `#btn_open_editor` = `編集画面を開く`
- 編集画面(タイトル `編集`): `#field_title`(ラベル `タイトル`・初期 空)/ `#txt_editor_state` = `panel=closed` /
  `#btn_open_panel` = `パネルを開く` → 画面内のパネル `#panel_inline`(本文 `#txt_panel` = `パネル`)を開く(`panel=open`)
- 戻る(`#btn_back`・Android の戻る・iOS のエッジスワイプ)の扱い:
  1. **パネルが開いていれば、パネルだけを閉じる**(`panel=closed`。画面は戻らない)
  2. 欄が空のままなら、そのまま戻る → `back=clean`
  3. 欄に文字があれば戻らずに確認ダイアログ: `#txt_discard_title` = `変更を破棄しますか?`・
     `#btn_discard` = `破棄`(戻る → `back=discarded`)・`#btn_keep` = `編集を続ける`(残る。欄の値はそのまま)
- iOS のエッジスワイプは、2・3 のどちらも上と同じ結果になるのが理想。**定番の作りでエッジスワイプを
  横取りできない SUT は、欄に文字がある間エッジスワイプを無効にし**、その旨を SUT の契約に書く
  (Flutter の `PopScope` がまさにそう振る舞う)
- **罠**: 戻るが遷移しないで終わる。戻るのあとにダイアログが割り込む。OS で挙動が割れる

## A9 引き伸ばせるシート(タイトル `引き伸ばせるシート`)

実例: AntennaPod のミニプレーヤー(`BottomSheetBehavior`)・immich / AppFlowy の
`DraggableScrollableSheet`・IceCubes / element-x の `presentationBackgroundInteraction(.enabled)`。

- 上部の固定領域: `#txt_sheet_state` = `sheet=collapsed|half|expanded`(止まった時点の値)/
  `#txt_player_result` = `player=none`
- 背面: 縦の一覧 `#row_main_00` … `#row_main_39` = `本文 00` …(押すと `player=main:row_main_05`)。
  **シートが畳まれている間も背面は押せる**。一覧の下端には畳んだシートの高さぶんの余白を置く
  (最後の行がシートの裏に潜らない)
- 常駐のシート(閉じることはできない。下へ払っても畳まれるだけ):
  - **畳んだ状態**(初期・高さ約 64dp/pt): ミニプレーヤー `#mini_player`。`#txt_mini_title` = `再生中: トラック 1`・
    `#btn_mini_play` = `再生`(押すと `一時停止` ⇄ `再生`。`player=play` / `player=pause`)
  - ミニプレーヤーの本体(ボタン以外)を**押すと半分**(`half`・画面の約 50%)、**上へ払うと**半分か全開
  - **半分・全開**: 見出し `#txt_player_title` = `トラック 1`・`#btn_player_collapse`(アイコンだけ・説明 `畳む`)・
    キューの一覧 `#list_queue`(`#queue_row_00` … `#queue_row_29` = `キュー 00` …。押すと `player=queue:queue_row_21`)
  - **半分の状態でキューを上へ払うと、まずシートが全開まで伸び、伸び切ってからキューが送られる**
    (`DraggableScrollableSheet` / `BottomSheetBehavior` の既定の振る舞い)
  - 全開でキューが先頭にあるとき下へ払うとシートが縮む
- 三段(畳む・半分・全開)を定番で持てないフレームワークは二段(畳む・全開)でよい(SUT の契約に書く)
- 畳んだ状態でキューを木に残すかどうかはその定番に従う(残るなら SUT の契約に書く)
- **罠**: 探索のスワイプがシートの伸縮に吸われる(1回目は中身が動かない)。背面とシートの両方が
  操作できる(シートの裏は覆われている、という前提が成り立たない)

## A10 スクロールで隠れるバー(タイトル `スクロールで隠れるバー`)

実例: Thunderbird の `HideFabOnScrollBehavior`・Signal / Confetti の enterAlways のバー・
wikipedia-ios の `hidesBarsOnSwipe`・iOS 26 の `tabBarMinimizeBehavior`。

- 上部の固定領域(**隠れない**): `#txt_hide_result` = `hide=none` / `#txt_bars_state` = `bars=shown|hidden`
  (止まった時点の値)
- その下に**隠れる上部バー** `#bar_top_hiding`(見出し `受信トレイ`・アクション `#btn_top_action` = `並べ替え`)
- 一覧 `#row_h_00` … `#row_h_59` = `行 H00` …(押すと `hide=row_h_33`)
- 右下の FAB `#fab_hiding`(アイコンだけ・説明 `作成`)→ `hide=fab`
- 下部のバー `#bar_bottom_hiding`: `#btn_bottom_a` = `受信` / `#btn_bottom_b` = `フォルダ` → `hide=bottom_a` / `hide=bottom_b`
- `#btn_top_action` → `hide=top_action`
- **下へ送る(内容が上へ動く)と、上部バー・FAB・下部バーが隠れる**(`bars=hidden`)。**少しでも上へ
  送り返すと現れる**(`bars=shown`)。隠れ方(画面外へ平行移動・木から消える)はその定番に従う
- **罠**: 直前に送った向き次第で、撃つ対象が消えている・画面外へ動いている

## A11 折りたたみヘッダとタブ(タイトル `折りたたみヘッダとタブ`)

実例: Eigen の `react-native-collapsible-tab-view`・Flutter の `NestedScrollView` + `TabBarView`・
Android の `CoordinatorLayout` + `AppBarLayout` + `ViewPager2`。

- 上部の固定領域: `#txt_tabhdr_result` = `tabhdr=none` / `#txt_tabhdr_tab` = `tab=posts|media|likes` /
  `#txt_tabhdr_header` = `header=expanded|collapsed`(止まった時点。見出しが一部でも見えていれば expanded)
- その下に**縮むヘッダ**(高さ約 200dp/pt): `#txt_profile_header` = `プロフィール見出し`・`#btn_follow` = `フォロー`
  (→ `tabhdr=follow`)
- ヘッダの下にタブ: `#tab_posts` = `投稿` / `#tab_media` = `メディア` / `#tab_likes` = `いいね`。
  **タブの列はヘッダが縮んでも上端に貼り付く**
- タブの中身は左右に払って切り替わるページで、それぞれ縦の一覧:
  `#post_00` … `#post_39` = `投稿 00` … / `#media_00` … `#media_39` = `メディア 00` … / `#like_00` … `#like_39` = `いいね 00` …
  (押すと `tabhdr=post_27` 等)
- 一覧を下へ送ると、**まずヘッダが縮み、縮み切ってから一覧が送られる**。上端まで戻すとヘッダが戻る
- **罠**: 1回目の送りがヘッダの縮みに吸われる。縦の容器(一覧)と横の容器(ページ)と、ヘッダの
  入れ子が同時にある。タブを替えると一覧の位置がタブごとに違う
- 定番で左右に払うページを持てない SUT は、タブを押す切り替えだけでよい(SUT の契約に書く)

## A12 高さの揃わないグリッド(タイトル `高さの揃わないグリッド`)

実例: nowinandroid のフィード(`LazyVerticalStaggeredGrid`)・tivi・Wikipedia(`StaggeredGridLayoutManager`)。

- 上部の固定領域: `#txt_staggered_result` = `stag=none`
- 2 列のグリッド `#grid_staggered`、タイル `#stag_00` … `#stag_59` = `タイル 00` …
- タイル i の高さ = `80 + ((i * 37) % 5) * 30` dp/pt(80〜200。決定的に揃わない)
- 押すと `stag=stag_47`
- **罠**: 木の並び順(i の順)と見た目の上下順が一致しない(列ごとに短い方へ詰める)。
  「次の行」「末尾」の判定が普通のグリッドと違う
- 実装の例: Compose `LazyVerticalStaggeredGrid` / Flutter `MasonryGridView`(flutter_staggered_grid_view)/
  RN `FlashList` の `masonry` / Android `StaggeredGridLayoutManager` / iOS 列ごとの `LazyVStack` を 2 本並べる
  か `UICollectionView` の自前レイアウト

## 付録: 範囲表記の展開(`fleetest project lint-selectors` の照合用)

本文の `00..59` のような範囲は字面の `#id` にならないので、ここに全部を並べる(生成:
`python3` で連番を出しただけ。本文の範囲を変えたらここも作り直す)。

#txt_shelf_0 #txt_shelf_1 #txt_shelf_2 #txt_shelf_3 #txt_shelf_4 #txt_shelf_5 #txt_shelf_6 #txt_shelf_7 #txt_shelf_8 #txt_shelf_9 #shelf_0 #shelf_1 #shelf_2 #shelf_3 #shelf_4 #shelf_5 #shelf_6 #shelf_7 #shelf_8 #shelf_9 #card_0_00 #card_0_01 #card_0_02 #card_0_03 #card_0_04 #card_0_05 #card_0_06 #card_0_07 #card_0_08 #card_0_09 #card_0_10 #card_0_11 #card_0_12 #card_0_13 #card_0_14 #card_1_00 #card_1_01 #card_1_02 #card_1_03 #card_1_04 #card_1_05 #card_1_06 #card_1_07 #card_1_08 #card_1_09 #card_1_10 #card_1_11 #card_1_12 #card_1_13 #card_1_14 #card_2_00 #card_2_01 #card_2_02 #card_2_03 #card_2_04 #card_2_05 #card_2_06 #card_2_07 #card_2_08 #card_2_09 #card_2_10 #card_2_11 #card_2_12 #card_2_13 #card_2_14 #card_3_00 #card_3_01 #card_3_02 #card_3_03 #card_3_04 #card_3_05 #card_3_06 #card_3_07 #card_3_08 #card_3_09 #card_3_10 #card_3_11 #card_3_12 #card_3_13 #card_3_14 #card_4_00 #card_4_01 #card_4_02 #card_4_03 #card_4_04 #card_4_05 #card_4_06 #card_4_07 #card_4_08 #card_4_09 #card_4_10 #card_4_11 #card_4_12 #card_4_13 #card_4_14 #card_5_00 #card_5_01 #card_5_02 #card_5_03 #card_5_04 #card_5_05 #card_5_06 #card_5_07 #card_5_08 #card_5_09 #card_5_10 #card_5_11 #card_5_12 #card_5_13 #card_5_14 #card_6_00 #card_6_01 #card_6_02 #card_6_03 #card_6_04 #card_6_05 #card_6_06 #card_6_07 #card_6_08 #card_6_09 #card_6_10 #card_6_11 #card_6_12 #card_6_13 #card_6_14 #card_7_00 #card_7_01 #card_7_02 #card_7_03 #card_7_04 #card_7_05 #card_7_06 #card_7_07 #card_7_08 #card_7_09 #card_7_10 #card_7_11 #card_7_12 #card_7_13 #card_7_14 #card_8_00 #card_8_01 #card_8_02 #card_8_03 #card_8_04 #card_8_05 #card_8_06 #card_8_07 #card_8_08 #card_8_09 #card_8_10 #card_8_11 #card_8_12 #card_8_13 #card_8_14 #card_9_00 #card_9_01 #card_9_02 #card_9_03 #card_9_04 #card_9_05 #card_9_06 #card_9_07 #card_9_08 #card_9_09 #card_9_10 #card_9_11 #card_9_12 #card_9_13 #card_9_14 #msg_00 #msg_01 #msg_02 #msg_03 #msg_04 #msg_05 #msg_06 #msg_07 #msg_08 #msg_09 #msg_10 #msg_11 #msg_12 #msg_13 #msg_14 #msg_15 #msg_16 #msg_17 #msg_18 #msg_19 #msg_20 #msg_21 #msg_22 #msg_23 #msg_24 #msg_25 #msg_26 #msg_27 #msg_28 #msg_29 #msg_30 #msg_31 #msg_32 #msg_33 #msg_34 #msg_35 #msg_36 #msg_37 #msg_38 #msg_39 #msg_40 #msg_41 #msg_42 #msg_43 #msg_44 #msg_45 #msg_46 #msg_47 #msg_48 #msg_49 #msg_50 #msg_51 #msg_52 #msg_53 #msg_54 #msg_55 #msg_56 #msg_57 #msg_58 #msg_59 #msg_60 #msg_61 #msg_62 #msg_63 #msg_64 #msg_65 #msg_66 #msg_67 #msg_68 #msg_69 #row_l_00 #row_l_01 #row_l_02 #row_l_03 #row_l_04 #row_l_05 #row_l_06 #row_l_07 #row_l_08 #row_l_09 #row_l_10 #row_l_11 #row_l_12 #row_l_13 #row_l_14 #row_l_15 #row_l_16 #row_l_17 #row_l_18 #row_l_19 #row_l_20 #row_l_21 #row_l_22 #row_l_23 #row_l_24 #row_l_25 #row_l_26 #row_l_27 #row_l_28 #row_l_29 #row_l_30 #row_l_31 #row_l_32 #row_l_33 #row_l_34 #row_l_35 #row_l_36 #row_l_37 #row_l_38 #row_l_39 #row_l_40 #row_l_41 #row_l_42 #row_l_43 #row_l_44 #row_l_45 #row_l_46 #row_l_47 #row_l_48 #row_l_49 #sw_row_1 #sw_row_2 #sw_row_3 #sw_row_4 #sw_row_5 #sw_row_6 #btn_sw_archive_1 #btn_sw_archive_2 #btn_sw_archive_3 #btn_sw_archive_4 #btn_sw_archive_5 #btn_sw_archive_6 #btn_sw_delete_1 #btn_sw_delete_2 #btn_sw_delete_3 #btn_sw_delete_4 #btn_sw_delete_5 #btn_sw_delete_6 #btn_sw_pin_1 #btn_sw_pin_2 #btn_sw_pin_3 #btn_sw_pin_4 #btn_sw_pin_5 #btn_sw_pin_6 #reply_row_1 #reply_row_2 #reply_row_3 #sel_row_01 #sel_row_02 #sel_row_03 #sel_row_04 #sel_row_05 #sel_row_06 #sel_row_07 #sel_row_08 #sel_row_09 #sel_row_10 #sel_row_11 #sel_row_12 #sel_row_13 #sel_row_14 #sel_row_15 #sel_row_16 #sel_row_17 #sel_row_18 #sel_row_19 #sel_row_20 #otp_box_1 #otp_box_2 #otp_box_3 #otp_box_4 #otp_box_5 #otp_box_6 #key_0 #key_1 #key_2 #key_3 #key_4 #key_5 #key_6 #key_7 #key_8 #key_9 #row_main_00 #row_main_01 #row_main_02 #row_main_03 #row_main_04 #row_main_05 #row_main_06 #row_main_07 #row_main_08 #row_main_09 #row_main_10 #row_main_11 #row_main_12 #row_main_13 #row_main_14 #row_main_15 #row_main_16 #row_main_17 #row_main_18 #row_main_19 #row_main_20 #row_main_21 #row_main_22 #row_main_23 #row_main_24 #row_main_25 #row_main_26 #row_main_27 #row_main_28 #row_main_29 #row_main_30 #row_main_31 #row_main_32 #row_main_33 #row_main_34 #row_main_35 #row_main_36 #row_main_37 #row_main_38 #row_main_39 #queue_row_00 #queue_row_01 #queue_row_02 #queue_row_03 #queue_row_04 #queue_row_05 #queue_row_06 #queue_row_07 #queue_row_08 #queue_row_09 #queue_row_10 #queue_row_11 #queue_row_12 #queue_row_13 #queue_row_14 #queue_row_15 #queue_row_16 #queue_row_17 #queue_row_18 #queue_row_19 #queue_row_20 #queue_row_21 #queue_row_22 #queue_row_23 #queue_row_24 #queue_row_25 #queue_row_26 #queue_row_27 #queue_row_28 #queue_row_29 #row_h_00 #row_h_01 #row_h_02 #row_h_03 #row_h_04 #row_h_05 #row_h_06 #row_h_07 #row_h_08 #row_h_09 #row_h_10 #row_h_11 #row_h_12 #row_h_13 #row_h_14 #row_h_15 #row_h_16 #row_h_17 #row_h_18 #row_h_19 #row_h_20 #row_h_21 #row_h_22 #row_h_23 #row_h_24 #row_h_25 #row_h_26 #row_h_27 #row_h_28 #row_h_29 #row_h_30 #row_h_31 #row_h_32 #row_h_33 #row_h_34 #row_h_35 #row_h_36 #row_h_37 #row_h_38 #row_h_39 #row_h_40 #row_h_41 #row_h_42 #row_h_43 #row_h_44 #row_h_45 #row_h_46 #row_h_47 #row_h_48 #row_h_49 #row_h_50 #row_h_51 #row_h_52 #row_h_53 #row_h_54 #row_h_55 #row_h_56 #row_h_57 #row_h_58 #row_h_59 #post_00 #post_01 #post_02 #post_03 #post_04 #post_05 #post_06 #post_07 #post_08 #post_09 #post_10 #post_11 #post_12 #post_13 #post_14 #post_15 #post_16 #post_17 #post_18 #post_19 #post_20 #post_21 #post_22 #post_23 #post_24 #post_25 #post_26 #post_27 #post_28 #post_29 #post_30 #post_31 #post_32 #post_33 #post_34 #post_35 #post_36 #post_37 #post_38 #post_39 #media_00 #media_01 #media_02 #media_03 #media_04 #media_05 #media_06 #media_07 #media_08 #media_09 #media_10 #media_11 #media_12 #media_13 #media_14 #media_15 #media_16 #media_17 #media_18 #media_19 #media_20 #media_21 #media_22 #media_23 #media_24 #media_25 #media_26 #media_27 #media_28 #media_29 #media_30 #media_31 #media_32 #media_33 #media_34 #media_35 #media_36 #media_37 #media_38 #media_39 #like_00 #like_01 #like_02 #like_03 #like_04 #like_05 #like_06 #like_07 #like_08 #like_09 #like_10 #like_11 #like_12 #like_13 #like_14 #like_15 #like_16 #like_17 #like_18 #like_19 #like_20 #like_21 #like_22 #like_23 #like_24 #like_25 #like_26 #like_27 #like_28 #like_29 #like_30 #like_31 #like_32 #like_33 #like_34 #like_35 #like_36 #like_37 #like_38 #like_39 #stag_00 #stag_01 #stag_02 #stag_03 #stag_04 #stag_05 #stag_06 #stag_07 #stag_08 #stag_09 #stag_10 #stag_11 #stag_12 #stag_13 #stag_14 #stag_15 #stag_16 #stag_17 #stag_18 #stag_19 #stag_20 #stag_21 #stag_22 #stag_23 #stag_24 #stag_25 #stag_26 #stag_27 #stag_28 #stag_29 #stag_30 #stag_31 #stag_32 #stag_33 #stag_34 #stag_35 #stag_36 #stag_37 #stag_38 #stag_39 #stag_40 #stag_41 #stag_42 #stag_43 #stag_44 #stag_45 #stag_46 #stag_47 #stag_48 #stag_49 #stag_50 #stag_51 #stag_52 #stag_53 #stag_54 #stag_55 #stag_56 #stag_57 #stag_58 #stag_59

## CMP の実装

CMP 1.11.0 / Kotlin 2.4.10 / Material3(commonMain)。追加の依存は `org.jetbrains.compose.ui:ui-backhandler:1.11.0`
(commonMain の `BackHandler`。navigation-compose が推移的に引くのと同じ版)だけ。ビルド: `scripts/build-ios.sh`(→
`dist/ios-simulator/FTE2EY.app`)・`scripts/build-android.sh`(→ `dist/android/ft-e2ey-debug.apk`)。

### 画面 → 使った部品

| 画面 | 部品 |
|---|---|
| A1 入れ子スクロール | `LazyColumn` の中に `LazyRow`(`#list_nested` / `#shelf_i`) |
| A2 反転チャット | `LazyColumn(reverseLayout = true)`(index 0 = 最新)・`imePadding()` の入力バー・`animateScrollToItem(0)` |
| A3 読み込みの状態 | `LazyColumn`。骨組みは `clickable(enabled = false)`(灰色の静的な帯・シマー無し)。末尾の読み込みは `LaunchedEffect` + 固定秒の `delay` |
| A4 スワイプの操作 | `AnchoredDraggableState` + `Modifier.anchoredDraggable`(自前の行。アンカー = 閉じる 0 / ボタン -160dp / 全払い -行幅 / ピン +80dp)。返信行は `Modifier.draggable` |
| A5 選択モード | `combinedClickable`(通常)/ `toggleable`(選択中)。行頭の印は a11y から外す |
| A6 文中リンク | `AnnotatedString` + `LinkAnnotation.Clickable`(`withLink`)。入れ子は `clickable` の行の中の `Text` |
| A7 PIN と OTP | 隠れた `BasicTextField`(`alpha(0f)`・`#field_otp`)+ 箱の `clickable`(`focusRequester` + `keyboard.show()`)・PIN は `Button` 10 個の自前キーパッド |
| A8 戻るの横取り | `BackHandler`(`androidx.compose.ui.backhandler`)+ `AlertDialog`。編集画面は別ルート(タイトル `編集`) |
| A9 引き伸ばせるシート | `BottomSheetScaffold` + `rememberStandardBottomSheetState`(常駐・`skipHiddenState = true`) |
| A10 スクロールで隠れるバー | `Modifier.nestedScroll`(自前の `NestedScrollConnection`)+ `graphicsLayer { translationY }` |
| A11 折りたたみヘッダとタブ | 自前の `NestedScrollConnection`(ヘッダの縮み)+ `PrimaryTabRow` + `HorizontalPager` |
| A12 高さの揃わないグリッド | `LazyVerticalStaggeredGrid(StaggeredGridCells.Fixed(2))` |

### 契約からの逸脱・CMP 固有の挙動

- **A9: 三段を二段 + peekHeight で作った**。Material3 のシートは畳む(`PartiallyExpanded`)と全開(`Expanded`)の二段。
  畳んだ高さ(`sheetPeekHeight`)を 64dp / 画面の 50% に切り替えて「畳む / 半分」を作る。ミニプレーヤーを押すと半分・
  `#btn_player_collapse` で畳む・上へ払うと全開・**全開から下へ払うと畳む(半分には止まらない)**。**半分から下へ払っても
  畳まれない**(契約の「下へ払っても畳まれる」から外れる)。`sheet=` はシートの `currentValue`(止まった時点)と半分の印から作る
- **A9: 畳んだ状態でもキュー・見出し(`#txt_player_title` / `#btn_player_collapse` / `#queue_row_NN`)は木に居る**
  (シート内容は常に composition される。画面外に置かれるだけ)。シートの内容が constant でないと高さの基準が循環するため
- **A9: 内容の下側は半分のとき画面外**。キューの高さは全開で画面を満たす値に固定しているので、半分のときは下の行が画面の下にはみ出す
- **A8: iOS のエッジスワイプ(横取り)は未確認**。commonMain の `BackHandler` が iOS の戻るジェスチャを横取りするかは CMP の
  版次第で、この SUT は確認していない(横取りされなければエッジスワイプは確認ダイアログを飛ばして戻る = 契約の「理想」から外れる)。
  `#btn_back`(シェルの戻る)は `BackBridge` 経由で同じ処理を呼ぶので Android・iOS とも横取りされる。`BackHandler` は
  この版で deprecated(NavigationEventHandler への移行を促す警告)だが動く
- **A7: PIN の 4 桁目は `pin_len=0` に戻す**(確定と同時に空へ。`pin_len=4` は読めない)
- **A3: シマーのアニメーションは付けない**(アイドル待ちを妨げないため)。骨組みは enabled=false の灰色の帯
- **A10: バーは平行移動で隠す**(木には居続ける・画面外の座標になる)。隠れる/現れるの切り替えは送りの向きの符号だけで決め、
  `bars=` は切り替え直後の値(アニメーションは約 300ms)
- **A11: ヘッダはタブを替えても共有**(縮み具合はタブごとに持たない)。一覧の位置はタブごと(`HorizontalPager` が各ページの
  `LazyColumn` を保持)。縦の一覧は `#id` を持たない(契約に無い)ので、縦の探索の `scrollFrame` は省略する
- **A10: 一覧にも `#id` を付けていない**(契約に無い)
- iOS は `ComposeUIViewController` の `onFocusBehavior = DoNothing`(E2EX と同じ。既定の `FocusableAboveKeyboard` は
  キーボードの高さぶん画面全体を押し上げ、上部に固定した echo を画面外へ出す)。A2 の入力バーは `imePadding()` で避ける

### 確認できていない性質

- A6: 行全体が `clickable` の中の `LinkAnnotation`(こちら)が、親の `clickable` を食うか(押すとどちらが反応するか)
- A5: `toggleable` の選択状態が `checkIsON()` で読めるか(Android: `selected`/`checked`、iOS: a11y の value の出方)
- A4: `AnchoredDraggable` の既定のしきい値で、シナリオの払う距離(-0.45 / -0.9 / +0.3)が狙いのアンカーへ落ちるか
