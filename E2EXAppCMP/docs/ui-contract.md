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
  その下に `LazyColumn` の行 `#row_sheet_00..29` = `シート行 00..29`(押すと echo)。一覧そのものに `#list_sheet`
  (半分開きのシートでは画面中央がシートの縁に当たるので、探索は `scrollFrame: "#list_sheet"` で指す)
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

#list_sheet #btn_sheet_opt_1 #btn_sheet_opt_2 #btn_sheet_opt_3 #txt_page_0 #txt_page_1 #txt_page_2 #txt_page_3 #txt_page_4 #btn_page_0 #btn_page_1 #btn_page_2 #btn_page_3 #btn_page_4 #row_sheet_00 #row_sheet_01 #row_sheet_02 #row_sheet_03 #row_sheet_04 #row_sheet_05 #row_sheet_06 #row_sheet_07 #row_sheet_08 #row_sheet_09 #row_sheet_10 #row_sheet_11 #row_sheet_12 #row_sheet_13 #row_sheet_14 #row_sheet_15 #row_sheet_16 #row_sheet_17 #row_sheet_18 #row_sheet_19 #row_sheet_20 #row_sheet_21 #row_sheet_22 #row_sheet_23 #row_sheet_24 #row_sheet_25 #row_sheet_26 #row_sheet_27 #row_sheet_28 #row_sheet_29 #row_refresh_00 #row_refresh_01 #row_refresh_02 #row_refresh_03 #row_refresh_04 #row_refresh_05 #row_refresh_06 #row_refresh_07 #row_refresh_08 #row_refresh_09 #row_refresh_10 #row_refresh_11 #row_refresh_12 #row_refresh_13 #row_refresh_14 #row_refresh_15 #row_refresh_16 #row_refresh_17 #row_refresh_18 #row_refresh_19 #cell_00 #cell_01 #cell_02 #cell_03 #cell_04 #cell_05 #cell_06 #cell_07 #cell_08 #cell_09 #cell_10 #cell_11 #cell_12 #cell_13 #cell_14 #cell_15 #cell_16 #cell_17 #cell_18 #cell_19 #cell_20 #cell_21 #cell_22 #cell_23 #cell_24 #cell_25 #cell_26 #cell_27 #cell_28 #cell_29 #cell_30 #cell_31 #cell_32 #cell_33 #cell_34 #cell_35 #cell_36 #cell_37 #cell_38 #cell_39 #cell_40 #cell_41 #cell_42 #cell_43 #cell_44 #cell_45 #cell_46 #cell_47 #cell_48 #cell_49 #cell_50 #cell_51 #cell_52 #cell_53 #cell_54 #cell_55 #cell_56 #cell_57 #cell_58 #cell_59 #cell_60 #cell_61 #cell_62 #cell_63 #cell_64 #cell_65 #cell_66 #cell_67 #cell_68 #cell_69 #cell_70 #cell_71 #cell_72 #cell_73 #cell_74 #cell_75 #cell_76 #cell_77 #cell_78 #cell_79 #cell_80 #cell_81 #cell_82 #cell_83 #cell_84 #cell_85 #cell_86 #cell_87 #cell_88 #cell_89 #swipe_row_1 #swipe_row_2 #swipe_row_3 #swipe_row_4 #swipe_row_5 #stab_01 #stab_02 #stab_03 #stab_04 #stab_05 #stab_06 #stab_07 #stab_08 #stab_09 #stab_10 #stab_11 #stab_12 #detail_link_1 #detail_link_2 #detail_link_3

## 第2弾の実装(CMP)

`docs/ui-contract-wave2.md` の 13 画面を Compose Multiplatform の定番部品で実装する
(SUT 間で共通の契約は前者、CMP 固有の実装選択・逸脱はここに書く)。

| 画面 | 部品 |
|---|---|
| 伸縮するヘッダ | 画面ローカル `Scaffold` + `LargeTopAppBar` + `TopAppBarDefaults.exitUntilCollapsedScrollBehavior()` |
| 貼り付く見出し | `LazyColumn` の `stickyHeader` |
| 時刻ピッカー | `AlertDialog` + `TimePicker` / `TimeInput`(モード切替は自前ボタン `#btn_time_mode_toggle`) |
| ダイアログ | `AlertDialog`(アラート・入力つき)/ `ModalBottomSheet`(アクションシート代替)/ `Dialog(usePlatformDefaultWidth = false)`(全画面) |
| 長押しメニュー | `combinedClickable(onLongClick)` + `DropdownMenu` |
| 並べ替え | 自前実装(`detectDragGesturesAfterLongPress` + しきい値超えで指の下のスロットへホップ。定番コンポーネント無し) |
| 入力の種類 | `OutlinedTextField`(`KeyboardOptions` / `PasswordVisualTransformation` / `minLines`)+ `ExposedDropdownMenuBox`(編集可)+ echo は非スクロールの固定領域・欄はスクロール領域の `imePadding()` |
| FAB | 画面ローカル `Scaffold` の `floatingActionButton`(`FloatingActionButton` + `ExtendedFloatingActionButton`)+ `bottomBar`(`BottomAppBar`) |
| 展開するリスト | `AnimatedVisibility` |
| ステッパーと進捗 | +/- ボタン + `LinearProgressIndicator`(`Animatable` で 2 秒アニメーション)+ `CircularProgressIndicator` |
| 無限スクロール | `LazyColumn` + `snapshotFlow { listState.layoutInfo }` による末尾検知・追加読み込み |
| ピンチで拡大 | `Modifier.transformable` + `graphicsLayer` |
| 固有部品 | M3 `HorizontalMultiBrowseCarousel` / `NavigationRail` / `BottomSheetScaffold` |

`docs/ui-contract-wave2.md` からの逸脱:

- **`#btn_toast` は実装しない**。トーストは commonMain に定番部品が無く(Android の `Toast` は
  androidMain 専用)、共通化すると「最小サポート画面で操作ボタンと echo が同時に木に載る」
  全体規約を満たせない
- **伸縮するヘッダは画面ローカルの `Scaffold`(`LargeTopAppBar`)を使う**ため、ルートの
  `TopAppBar`(`#txt_screen_title` / `#btn_back`)も残ったまま二重に表示される(契約が明示的に許容)
- **並べ替えは Compose/Foundation に定番コンポーネントが無い**ため、長押し+ドラッグ+しきい値超えで
  自前実装(補間なし。1回の pointer イベントで複数スロットぶんの移動量が来ても while でホップを
  繰り返し、指を離した位置ではなく、しきい値を跨いだ時点で1スロットずつ即座に確定する)
- **アクションシートは CMP にネイティブの action sheet が無い**ため `ModalBottomSheet` で代替
  (契約が候補として挙げている代替をそのまま採用)

#row_c_00 #row_c_01 #row_c_02 #row_c_03 #row_c_04 #row_c_05 #row_c_06 #row_c_07 #row_c_08 #row_c_09 #row_c_10 #row_c_11 #row_c_12 #row_c_13 #row_c_14 #row_c_15 #row_c_16 #row_c_17 #row_c_18 #row_c_19 #row_c_20 #row_c_21 #row_c_22 #row_c_23 #row_c_24 #row_c_25 #row_c_26 #row_c_27 #row_c_28 #row_c_29 #row_c_30 #row_c_31 #row_c_32 #row_c_33 #row_c_34 #row_c_35 #row_c_36 #row_c_37 #row_c_38 #row_c_39 #row_c_40 #row_c_41 #row_c_42 #row_c_43 #row_c_44 #row_c_45 #row_c_46 #row_c_47 #row_c_48 #row_c_49 #hdr_A #hdr_B #hdr_C #hdr_D #hdr_E #hdr_F #hdr_G #hdr_H #row_s_A0 #row_s_A1 #row_s_A2 #row_s_A3 #row_s_A4 #row_s_A5 #row_s_A6 #row_s_A7 #row_s_A8 #row_s_A9 #row_s_B0 #row_s_B1 #row_s_B2 #row_s_B3 #row_s_B4 #row_s_B5 #row_s_B6 #row_s_B7 #row_s_B8 #row_s_B9 #row_s_C0 #row_s_C1 #row_s_C2 #row_s_C3 #row_s_C4 #row_s_C5 #row_s_C6 #row_s_C7 #row_s_C8 #row_s_C9 #row_s_D0 #row_s_D1 #row_s_D2 #row_s_D3 #row_s_D4 #row_s_D5 #row_s_D6 #row_s_D7 #row_s_D8 #row_s_D9 #row_s_E0 #row_s_E1 #row_s_E2 #row_s_E3 #row_s_E4 #row_s_E5 #row_s_E6 #row_s_E7 #row_s_E8 #row_s_E9 #row_s_F0 #row_s_F1 #row_s_F2 #row_s_F3 #row_s_F4 #row_s_F5 #row_s_F6 #row_s_F7 #row_s_F8 #row_s_F9 #row_s_G0 #row_s_G1 #row_s_G2 #row_s_G3 #row_s_G4 #row_s_G5 #row_s_G6 #row_s_G7 #row_s_G8 #row_s_G9 #row_s_H0 #row_s_H1 #row_s_H2 #row_s_H3 #row_s_H4 #row_s_H5 #row_s_H6 #row_s_H7 #row_s_H8 #row_s_H9 #ctx_row_1 #ctx_row_2 #ctx_row_3 #reorder_row_1 #reorder_row_2 #reorder_row_3 #reorder_row_4 #reorder_row_5 #row_f_00 #row_f_01 #row_f_02 #row_f_03 #row_f_04 #row_f_05 #row_f_06 #row_f_07 #row_f_08 #row_f_09 #row_f_10 #row_f_11 #row_f_12 #row_f_13 #row_f_14 #row_f_15 #row_f_16 #row_f_17 #row_f_18 #row_f_19 #row_f_20 #row_f_21 #row_f_22 #row_f_23 #row_f_24 #row_f_25 #row_f_26 #row_f_27 #row_f_28 #row_f_29 #row_i_00 #row_i_01 #row_i_02 #row_i_03 #row_i_04 #row_i_05 #row_i_06 #row_i_07 #row_i_08 #row_i_09 #row_i_10 #row_i_11 #row_i_12 #row_i_13 #row_i_14 #row_i_15 #row_i_16 #row_i_17 #row_i_18 #row_i_19 #row_i_20 #row_i_21 #row_i_22 #row_i_23 #row_i_24 #row_i_25 #row_i_26 #row_i_27 #row_i_28 #row_i_29 #row_i_30 #row_i_31 #row_i_32 #row_i_33 #row_i_34 #row_i_35 #row_i_36 #row_i_37 #row_i_38 #row_i_39 #row_i_40 #row_i_41 #row_i_42 #row_i_43 #row_i_44 #row_i_45 #row_i_46 #row_i_47 #row_i_48 #row_i_49 #row_i_50 #row_i_51 #row_i_52 #row_i_53 #row_i_54 #row_i_55 #row_i_56 #row_i_57 #row_i_58 #row_i_59 #row_i_60 #row_i_61 #row_i_62 #row_i_63 #row_i_64 #row_i_65 #row_i_66 #row_i_67 #row_i_68 #row_i_69 #row_i_70 #row_i_71 #row_i_72 #row_i_73 #row_i_74 #row_i_75 #row_i_76 #row_i_77 #row_i_78 #row_i_79 #row_i_80 #row_i_81 #row_i_82 #row_i_83 #row_i_84 #row_i_85 #row_i_86 #row_i_87 #row_i_88 #row_i_89 #row_i_90 #row_i_91 #row_i_92 #row_i_93 #row_i_94 #row_i_95 #row_i_96 #row_i_97 #row_i_98 #row_i_99 #item_fruit_1 #item_fruit_2 #item_fruit_3 #item_veg_1 #item_veg_2 #item_veg_3 #item_drink_1 #item_drink_2 #item_drink_3 #carousel_item_0 #carousel_item_1 #carousel_item_2 #carousel_item_3 #carousel_item_4
