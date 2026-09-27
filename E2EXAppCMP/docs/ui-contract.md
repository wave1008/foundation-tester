# FT E2EX アプリ UI 契約(Compose Multiplatform 固有部品)

**E2EAppCMP との違い**: E2EAppCMP は「全フレームワークに共通の画面」(5 SUT 共通契約)だけを持つ。
**E2EXAppCMP は Compose Multiplatform の定番部品のうち、共通契約に載っていないもの**を並べ、
フレームワーク固有の癖を拾うための SUT。他 SUT との共通契約は無い(この文書が唯一の正)。

- bundle ID / applicationId: `com.ftester.e2ex`(E2EAppCMP の `com.ftester.e2e` と同居できる)
- 表示名: `FT E2EX`
- ディープリンク: 持たない
- シナリオ: `TestProjects/E2EX-CMP/scenarios/`

## 全体規約

- すべての操作結果は画面上の**echo テキスト**(`txt_*_result` 等)に ASCII の決定的な文字列で出す。
  シナリオはこの文字列で成否を確かめる(部品の内部状態を a11y で読めるとは仮定しない)
- testTag を付けられる所には全部付ける。**付けられない部品の内部**(DatePicker の日付セル・
  Snackbar のアクション・Tab の中身など)はラベルで指す前提 = それ自体が検証対象
- Android: ルートで `testTagsAsResourceId = true`。**Popup / Dialog / ModalBottomSheet /
  DropdownMenu / Tooltip の中身は別ウィンドウ**なので、その中のルートにも付け直す(共通 SUT と同じ作法)
- 状態は画面離脱で初期化してよい(永続化しない)
- 最小サポート画面(iPhone SE 相当・Pixel 4a)で、各画面の「操作ボタン」と「echo」が同時に木に載ること

## シェル

- Material3 `Scaffold` + `TopAppBar` + **navigation-compose の `NavHost`**(ルート文字列で遷移)
- `#txt_screen_title`: TopAppBar のタイトル(各画面の見出し文字列)
- `#btn_back`: TopAppBar の `navigationIcon` の `IconButton`。**アイコンだけ**(contentDescription `戻る`、
  テキスト無し)。ホームでは出さない。押すと `navController.popBackStack()`
- システムの戻る(Android の back・iOS のエッジスワイプ)も NavHost の既定動作に任せる

## ホーム(タイトル `E2EX ホーム`)

`LazyColumn` の `ListItem`(行全体が clickable)。testTag と見出し:

| testTag | 見出し | 遷移先 |
|---|---|---|
| `#nav_pager` | ページャ | ページャ |
| `#nav_sheet` | ボトムシート | ボトムシート |
| `#nav_menu` | メニュー | メニュー |
| `#nav_date` | 日付ピッカー | 日付ピッカー |
| `#nav_drawer` | ドロワー | ドロワー |
| `#nav_refresh` | 引っ張って更新 | 引っ張って更新 |
| `#nav_snackbar` | スナックバー | スナックバー |
| `#nav_grid` | グリッド | グリッド |
| `#nav_swipe` | スワイプで削除 | スワイプで削除 |
| `#nav_tabs` | タブ | タブ |
| `#nav_anim` | アニメーション | アニメーション |
| `#nav_tooltip` | ツールチップ | ツールチップ |
| `#nav_chips` | チップと分割ボタン | チップと分割ボタン |
| `#nav_search` | 検索バー | 検索バー |
| `#nav_detail` | 引数付き遷移 | 引数付き遷移 |

行の高さは Material3 の既定(1行 ListItem = 56dp)。**15 行あるので小さい画面では下の行が
折り返しの下に来る**(シナリオは `tap(..., scroll: .down)` で届かせる)。

## ページャ(タイトル `ページャ`)

- `#pager_main`: `HorizontalPager`(5 ページ、画面幅いっぱい、高さ 240dp)
- 各ページ N(0〜4): `txt_page_N` = `ページ N`、`btn_page_N` = `ページ N のボタン`(押すと echo)
- `#txt_pager_state`: `page=N`(`pagerState.settledPage`)
- `#txt_pager_result`: 初期 `pager=none`、ページ N のボタンで `pager=tapped N`
- `#btn_pager_next`: `次のページ`(`animateScrollToPage(current+1)`、最後なら何もしない)

## ボトムシート(タイトル `ボトムシート`)

- `#btn_open_sheet`: `シートを開く` → `ModalBottomSheet`(skipPartiallyExpanded = false の既定)
- シートの中: `#txt_sheet_title` = `シートの見出し`、`#btn_sheet_opt_1..3` = `選択肢 1..3`、
  その下に `LazyColumn` の行 `#row_sheet_00..29` = `シート行 00..29`(押すと echo)
- 選択肢/行を押すとシートを閉じて echo: `#txt_sheet_result` = `sheet=opt2` / `sheet=row17`
- スクリム・下スワイプ・戻るで閉じたら `sheet=dismissed`。初期 `sheet=none`

## メニュー(タイトル `メニュー`)

- `#btn_open_menu`: `メニューを開く` → `DropdownMenu`(`DropdownMenuItem` 3つ)
  `#menu_item_copy` = `コピー` / `#menu_item_share` = `共有` / `#menu_item_delete` = `削除`
- `#txt_menu_result`: 初期 `menu=none`、選ぶと `menu=copy` 等、メニュー外タップで閉じたら `menu=dismissed`
- `#field_fruit`: `ExposedDropdownMenuBox` の読み取り専用 `TextField`(ラベル `果物`、初期値 空)
  押すと候補 `#opt_fruit_apple` = `りんご` / `#opt_fruit_banana` = `バナナ` / `#opt_fruit_cherry` = `さくらんぼ`
- `#txt_fruit_result`: 初期 `fruit=none`、選ぶと `fruit=banana` 等

## 日付ピッカー(タイトル `日付ピッカー`)

- `#btn_open_date`: `日付を選ぶ` → `DatePickerDialog` + `DatePicker`
  (初期選択 **2026-01-15**(UTC)・表示月 2026年1月・displayMode = Picker)
- ダイアログのボタン: `#btn_date_ok` = `OK` / `#btn_date_cancel` = `キャンセル`
- 日付セルは DatePicker 内部なので testTag 無し(ラベルで指す)
- `#txt_date_result`: 初期 `date=none`、OK で `date=2026-01-20` 形式(選択が無ければ `date=null`)、
  キャンセルで `date=cancel`

## ドロワー(タイトル `ドロワー`)

- `ModalNavigationDrawer`(gesturesEnabled = true)
- `#btn_open_drawer`: `ドロワーを開く`
- ドロワーの中: `#txt_drawer_header` = `ドロワー見出し`、`NavigationDrawerItem`
  `#drawer_item_inbox` = `受信箱` / `#drawer_item_sent` = `送信済み` / `#drawer_item_trash` = `ゴミ箱`
- 選ぶとドロワーを閉じて `#txt_drawer_result` = `drawer=sent` 等。初期 `drawer=none`
- `#txt_drawer_state`: `drawerOpen=true|false`(`drawerState.isOpen`。アニメーション完了後の値)

## 引っ張って更新(タイトル `引っ張って更新`)

- `PullToRefreshBox`(`#box_refresh`)の中に `LazyColumn` の行 `#row_refresh_00..19` = `更新行 00..19`
- 引っ張ると 1.0 秒後に更新完了。`#txt_refresh_count` = `refresh=N`(完了回数。初期 `refresh=0`)
- `#txt_refresh_count` は PullToRefreshBox の**外**(上)に置く

## スナックバー(タイトル `スナックバー`)

- Scaffold の `SnackbarHost`
- `#btn_show_snackbar`: `スナックバーを出す` → メッセージ `削除しました`・アクション `元に戻す`・
  duration = `Long`(約 10 秒)
- `#btn_show_snackbar_short`: `短いスナックバー` → メッセージ `保存しました`・アクション無し・`Short`(約 4 秒)
- `#txt_snackbar_result`: 初期 `snackbar=none`、アクションで `snackbar=undo`、消えたら `snackbar=dismissed`、
  短い方が消えたら `snackbar=short-dismissed`
- Snackbar 内部には testTag を付けない(ラベルで指す)

## グリッド(タイトル `グリッド`)

- `#grid_main`: `LazyVerticalGrid`(3 列固定)、セル `#cell_00..89` = `セル 00..89`(高さ 96dp)
- 押すと `#txt_grid_result` = `grid=57` 等。初期 `grid=none`。echo はグリッドの**上**に固定

## スワイプで削除(タイトル `スワイプで削除`)

- `LazyColumn` の各行を `SwipeToDismissBox` で包む。行 `#swipe_row_1..5` = `スワイプ行 1..5`
- 右から左(EndToStart)で消える。左から右は無効(`enableDismissFromStartToEnd = false`)
- `#txt_swipe_result`: 初期 `removed=none`、消すと `removed=3` 等(最後に消した行)
- `#txt_swipe_count`: `rows=N`(残りの行数。初期 `rows=5`)

## タブ(タイトル `タブ`)

- `PrimaryTabRow`: `#tab_a` = `タブA` / `#tab_b` = `タブB` / `#tab_c` = `タブC`
  → `#txt_tab_content` = `content=A|B|C`(初期 A)
- `ScrollableTabRow` `#stab_row`(12 タブ、画面幅に収まらない): `#stab_01..12` = `項目タブ01..12`
  → `#txt_stab_content` = `scroll-tab=01..12`(初期 01)
- 画面下端に Material3 `NavigationBar`: `#navbar_home` = `ホーム` / `#navbar_search` = `探す` /
  `#navbar_settings` = `設定`(アイコン + ラベル)→ `#txt_navbar_result` = `navbar=home|search|settings`(初期 home)

## アニメーション(タイトル `アニメーション`)

- `#btn_toggle_anim`: `表示を切り替える` → `AnimatedVisibility`(fadeIn + expandVertically、
  **1500ms**)で `#txt_anim_target` = `アニメ完了` を出し入れ
- `#txt_anim_visible`: `visible=true|false`(ボタンを押した時点で切り替わる = アニメーション中から true)
- `#btn_anim_inc`: `増やす` → `AnimatedContent`(縦スライド 800ms)で `#txt_anim_count` = `count=N`(初期 0)

## ツールチップ(タイトル `ツールチップ`)

- `TooltipBox` + `PlainTooltip`。アンカーは `IconButton` `#btn_tooltip_anchor`(アイコンだけ・
  contentDescription `情報`)
- 長押しで `#txt_tooltip` = `これはツールチップです` が出る(Popup = 別ウィンドウ)
- `#txt_tooltip_state`: `tooltip=shown|hidden`(`tooltipState.isVisible`)

## チップと分割ボタン(タイトル `チップと分割ボタン`)

- `FilterChip` `#chip_wifi` = `Wi-Fi`(初期 未選択)→ `#txt_chip_result` = `wifi=true|false`
- `AssistChip` `#chip_assist` = `ヘルプ` → `#txt_assist_result` = `assist=tapped`(初期 `assist=none`)
- `SingleChoiceSegmentedButtonRow`: `#seg_day` = `日` / `#seg_week` = `週` / `#seg_month` = `月`
  → `#txt_seg_result` = `seg=day|week|month`(初期 day)
- `RangeSlider` `#range_slider`(0〜100、steps 無し、初期 20..80)
  → `#txt_range_result` = `range=20-80`(整数に丸める)

## 検索バー(タイトル `検索バー`)

- Material3 `SearchBar`(`inputField` = `SearchBarDefaults.InputField`、testTag `#field_search`、
  placeholder `検索`)。展開すると候補 `#suggestion_apple` = `apple` / `#suggestion_apricot` = `apricot` /
  `#suggestion_banana` = `banana`(入力文字で前方一致に絞る)
- 候補を押すかキーボードの検索で確定 → 折り畳んで `#txt_search_result` = `search=apricot`(初期 `search=none`)

## 引数付き遷移(タイトル `引数付き遷移`)

- `#detail_link_1..3` = `詳細 1..3` → ルート `detail/{id}` へ遷移
- 詳細画面(タイトル `詳細`): `#txt_detail_id` = `id=N`、`#btn_detail_next` = `次の詳細` で `detail/{N+1}` を積む

## 付録: 範囲表記の展開(`fleetest project lint-selectors` の照合用)

本文の `00..29` のような範囲は字面の `#id` にならないので、ここに全部を並べる。

#btn_sheet_opt_1 #btn_sheet_opt_2 #btn_sheet_opt_3 #txt_page_0 #txt_page_1 #txt_page_2 #txt_page_3 #txt_page_4 #btn_page_0 #btn_page_1 #btn_page_2 #btn_page_3 #btn_page_4 #row_sheet_00 #row_sheet_01 #row_sheet_02 #row_sheet_03 #row_sheet_04 #row_sheet_05 #row_sheet_06 #row_sheet_07 #row_sheet_08 #row_sheet_09 #row_sheet_10 #row_sheet_11 #row_sheet_12 #row_sheet_13 #row_sheet_14 #row_sheet_15 #row_sheet_16 #row_sheet_17 #row_sheet_18 #row_sheet_19 #row_sheet_20 #row_sheet_21 #row_sheet_22 #row_sheet_23 #row_sheet_24 #row_sheet_25 #row_sheet_26 #row_sheet_27 #row_sheet_28 #row_sheet_29 #row_refresh_00 #row_refresh_01 #row_refresh_02 #row_refresh_03 #row_refresh_04 #row_refresh_05 #row_refresh_06 #row_refresh_07 #row_refresh_08 #row_refresh_09 #row_refresh_10 #row_refresh_11 #row_refresh_12 #row_refresh_13 #row_refresh_14 #row_refresh_15 #row_refresh_16 #row_refresh_17 #row_refresh_18 #row_refresh_19 #cell_00 #cell_01 #cell_02 #cell_03 #cell_04 #cell_05 #cell_06 #cell_07 #cell_08 #cell_09 #cell_10 #cell_11 #cell_12 #cell_13 #cell_14 #cell_15 #cell_16 #cell_17 #cell_18 #cell_19 #cell_20 #cell_21 #cell_22 #cell_23 #cell_24 #cell_25 #cell_26 #cell_27 #cell_28 #cell_29 #cell_30 #cell_31 #cell_32 #cell_33 #cell_34 #cell_35 #cell_36 #cell_37 #cell_38 #cell_39 #cell_40 #cell_41 #cell_42 #cell_43 #cell_44 #cell_45 #cell_46 #cell_47 #cell_48 #cell_49 #cell_50 #cell_51 #cell_52 #cell_53 #cell_54 #cell_55 #cell_56 #cell_57 #cell_58 #cell_59 #cell_60 #cell_61 #cell_62 #cell_63 #cell_64 #cell_65 #cell_66 #cell_67 #cell_68 #cell_69 #cell_70 #cell_71 #cell_72 #cell_73 #cell_74 #cell_75 #cell_76 #cell_77 #cell_78 #cell_79 #cell_80 #cell_81 #cell_82 #cell_83 #cell_84 #cell_85 #cell_86 #cell_87 #cell_88 #cell_89 #swipe_row_1 #swipe_row_2 #swipe_row_3 #swipe_row_4 #swipe_row_5 #stab_01 #stab_02 #stab_03 #stab_04 #stab_05 #stab_06 #stab_07 #stab_08 #stab_09 #stab_10 #stab_11 #stab_12 #detail_link_1 #detail_link_2 #detail_link_3
