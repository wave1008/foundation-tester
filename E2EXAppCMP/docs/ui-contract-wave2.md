# FT E2EX 第2弾の画面契約(全 E2EX SUT 共通)

第1弾(`ui-contract.md`)の15画面に**足す**画面。全体規約(echo は ASCII の決定的な文字列・
testTag を付けられる所には全部付ける・付けられない部品の内部はラベルで指す・最小サポート画面で
操作ボタンと echo が同時に木に載る)は第1弾と同じ。**部品は各フレームワークの定番で実装する**
(対応表は各 SUT の `docs/ui-contract.md`)。定番が無い画面・部品は作らずに、その SUT の契約へ理由を書く。

ホームの一覧に第1弾の15行の後ろへ足す(`#id` と見出し):

| `#id` | 見出し | 画面タイトル |
|---|---|---|
| `#nav_collapse` | 伸縮するヘッダ | 伸縮するヘッダ |
| `#nav_sticky` | 貼り付く見出し | 貼り付く見出し |
| `#nav_time` | 時刻ピッカー | 時刻ピッカー |
| `#nav_dialogs` | ダイアログ | ダイアログ |
| `#nav_context` | 長押しメニュー | 長押しメニュー |
| `#nav_reorder` | 並べ替え | 並べ替え |
| `#nav_inputs` | 入力の種類 | 入力の種類 |
| `#nav_fab` | FAB | FAB |
| `#nav_expand` | 展開するリスト | 展開するリスト |
| `#nav_stepper` | ステッパーと進捗 | ステッパーと進捗 |
| `#nav_infinite` | 無限スクロール | 無限スクロール |
| `#nav_zoom` | ピンチで拡大 | ピンチで拡大 |
| `#nav_native` | 固有部品 | 固有部品 |

## 伸縮するヘッダ

- 伸縮するヘッダ(展開時は大きな見出し `#txt_collapse_header` = `大きな見出し`)+ その下の縦リスト
  `#row_c_00` … `#row_c_49`(`行 C00` …)。行を押すと `#txt_collapse_result` = `collapse=row_c_37` 等
- `#txt_collapse_result` はヘッダの中(ヘッダが縮んでも木に残る位置)に置く。初期 `collapse=none`
- 実装の例: Flutter `SliverAppBar(pinned, expandedHeight)` + `SliverList` / Android `CoordinatorLayout` +
  `CollapsingToolbarLayout` + `RecyclerView` / Compose `LargeTopAppBar` + `exitUntilCollapsedScrollBehavior` /
  iOS `.navigationBarTitleDisplayMode(.large)` + `List` / RN `Animated` のスクロール連動ヘッダ

## 貼り付く見出し

- セクション A〜H(各 10 行)。見出し `#hdr_A` … `#hdr_H`(`セクション A` …)は**スクロールしても上端に貼り付く**
- 行 `#row_s_A0` … `#row_s_H9`(`行 A0` …)。押すと `#txt_sticky_result` = `sticky=row_s_F3` 等(初期 `sticky=none`。リストの上に固定)
- 実装の例: Compose `LazyColumn` `stickyHeader` / Flutter `SliverPersistentHeader`(pinned)の並び /
  RN `SectionList stickySectionHeadersEnabled` / Android `RecyclerView` + 貼り付く見出しの ItemDecoration /
  iOS `List` の `Section`(plain スタイル)

## 時刻ピッカー

- `#btn_open_time` = `時刻を選ぶ` → 時刻ピッカー(初期 09:30・24時間表記)。**入力モード(数字を打つ)に切り替えられる部品はその口を残す**
- 確定 `#btn_time_ok` = `OK` / `#btn_time_cancel` = `キャンセル`(付けられなければラベルで指す)
- `#txt_time_result` = `time=14:45` 形式 / `time=cancel`。初期 `time=none`

## ダイアログ

`#txt_dialogs_result` の文字列は**下の表の値そのもの**(`alert=ok` 等。`dialogs=` を前置しない)。初期値だけ `dialogs=none`。

| `#id` | ラベル | 開くもの | 結果(`#txt_dialogs_result`) |
|---|---|---|---|
| `#btn_alert` | `アラート` | 確認アラート(`OK` / `キャンセル`) | `alert=ok` / `alert=cancel` |
| `#btn_prompt` | `入力つき` | 入力欄つきダイアログ(欄 `#field_prompt`・`保存` / `キャンセル`) | `prompt=<入力>` / `prompt=cancel` |
| `#btn_action_sheet` | `アクションシート` | アクションシート(`写真を撮る` / `ライブラリから選ぶ` / `キャンセル`) | `sheet=camera` / `sheet=library` / `sheet=cancel` |
| `#btn_fullscreen` | `全画面` | 全画面ダイアログ(見出し `#txt_fullscreen_title` = `全画面ダイアログ`・`#btn_fullscreen_save` = `保存`・`#btn_fullscreen_close` = 閉じる) | `fullscreen=saved` / `fullscreen=closed` |
| `#btn_toast` | `トースト` | OS のトースト(Android の `Toast`・`保存しました` 約2秒)。**定番の無い OS は作らない** | `toast=shown`(押した時点) |

## 長押しメニュー

- 行 `#ctx_row_1` … `#ctx_row_3`(`長押し行 1` …)を長押しするとコンテキストメニュー(`編集` / `複製` / `削除`)
- `#txt_context_result` = `context=row2:copy` 等(初期 `context=none`)
- 実装の例: iOS `.contextMenu` / Android `registerForContextMenu` か長押しの `PopupMenu` / Flutter 長押し + `showMenu`
  (Cupertino なら `CupertinoContextMenu`)/ Compose `combinedClickable(onLongClick)` + `DropdownMenu` / RN 長押し + メニュー

## 並べ替え

- 行 `#reorder_row_1` … `#reorder_row_5`(`並べ替え 1` …)を**ドラッグで並べ替える**。
  **離した位置の行の場所へ移る**(2行ぶん下で離せば2つ下へ。隣と1回入れ替えるだけにしない)(長押ししてから動かす形・ハンドルを掴む形のどちらでも。その SUT の定番に従う)
- `#txt_reorder_result` = `order=1,2,3,4,5`(現在の並び。初期値もこの形)
- 実装の例: Flutter `ReorderableListView` / Android `ItemTouchHelper`(上下の移動)/ iOS `List` + `.onMove`(`EditButton` か常時編集)/
  RN `react-native-draggable-flatlist` / Compose 長押しドラッグの自前実装(定番ライブラリが無いことを契約に書く)

## 入力の種類

**echo はすべて画面上部の固定領域(スクロールしない・キーボードに隠れない位置)にまとめて置く**。
欄はその下のスクロール領域に並べる(キーボードが出ると echo が画面外・キーボードの下に隠れ、
Android では木から消えるため)。

| `#id` | 種類 | echo |
|---|---|---|
| `#field_number` | 数字キーパッド(ラベル `数量`) | `#txt_number_echo` = `number=<値>` |
| `#field_password` | パスワード(ラベル `パスワード`) | `#txt_password_echo` = `password_len=<文字数>` |
| `#field_multiline` | 複数行(ラベル `メモ`・3 行ぶんの高さ) | `#txt_multiline_echo` = `lines=<行数>` |
| `#field_first` → `#field_second` | IME の「次へ」で次の欄へ焦点が移る(ラベル `姓` / `名`) | `#txt_focus_echo` = `focus=second`(2つ目が焦点を得たら) |
| `#field_auto` | オートコンプリート(ラベル `国`・候補 `Japan` / `Jamaica` / `Jordan` を前方一致で。候補 `#auto_opt_japan` 等) | `#txt_auto_echo` = `auto=Japan` |
| `#field_bottom` | 画面の下端にある欄(キーボードに隠れる位置。ラベル `下の欄`) | `#txt_bottom_echo` = `bottom=<値>` |

## FAB

- `#fab_add` = FAB(アイコンだけ・説明 `追加`)→ `#txt_fab_result` = `fab=add`
- `#fab_extended` = 拡張 FAB(`新規作成`)→ `fab=extended`
- 画面下のバー(BottomAppBar 相当。定番の無い OS はツールバー)に `#bar_action_search` = `検索` / `#bar_action_share` = `共有` → `fab=search` / `fab=share`
- 初期 `fab=none`。FAB はリスト(`#row_f_00` … `#row_f_29`)の上に浮かぶ(リストの行を覆う位置)

## 展開するリスト

- グループ `#group_fruit` = `果物` / `#group_veg` = `野菜` / `#group_drink` = `飲み物`(閉じた状態で始まる)
- 開くと子 `#item_fruit_1` … `#item_fruit_3` 等(`りんご`・`みかん`・`ぶどう` / `にんじん`・`たまねぎ`・`キャベツ` / `水`・`お茶`・`コーヒー`)
- 子を押すと `#txt_expand_result` = `expand=item_veg_2` 等(初期 `expand=none`)
- 実装の例: Flutter `ExpansionTile` / Android `ExpandableListView` か RecyclerView の開閉 / iOS `DisclosureGroup` /
  Compose `AnimatedVisibility` の開閉 / RN `Pressable` + `LayoutAnimation`

## ステッパーと進捗

- 数量のステッパー `#stepper_qty`(増 `#btn_qty_plus` / 減 `#btn_qty_minus`。iOS は `Stepper` の +/-)→ `#txt_qty` = `qty=3`(初期 1・範囲 0〜10)
- `#btn_start_progress` = `進捗を開始` → 決定的な進捗バー `#progress_main` が 2 秒で 0→100%。終わったら `#txt_progress` = `progress=done`(初期 `progress=idle`、進行中 `progress=running`)
- 不定の回転インジケータ `#spinner_busy` は進行中だけ表示

## 無限スクロール

- 一覧 `#list_infinite`。最初は `#row_i_00` … `#row_i_19`(`項目 00` …)。末尾近くまで送ると 0.8 秒後に次の 20 行を足す(最大 100 行)。
  読み込み中は末尾に `#txt_loading` = `読み込み中`
- `#txt_infinite_count` = `loaded=20`(読み込み済みの行数。リストの上に固定)
- 行を押すと `#txt_infinite_result` = `infinite=row_i_57` 等(初期 `infinite=none`)

## ピンチで拡大

- 画像(または図形)`#zoom_target` を**ピンチで拡大・縮小・パン**できる(Flutter `InteractiveViewer` / Compose `transformable` /
  iOS `MagnifyGesture` か `UIScrollView` の zoom / Android `ScaleGestureDetector` か定番ライブラリ / RN gesture-handler の Pinch)
- **拡大した中身は `#zoom_target` の枠の外へはみ出さない**(枠で切り取る。はみ出すと echo を覆う)
- `#txt_zoom_scale` = `scale=1.0`(小数1桁。拡大後 `scale=2.0` 等。上限 4.0・下限 1.0)
- `#btn_zoom_reset` = `元に戻す` → `scale=1.0`

## 固有部品(`#nav_native`)

その SUT のフレームワークに**固有の**定番部品を、ボタン1つ・echo 1つずつで並べる。中身は SUT ごとに違う(各 SUT の契約に表を置く)。
echo は `#txt_native_result` 1つに `native=<部品名>:<値>` の形で出す(初期 `native=none`)。候補:
- Flutter: `Hero` での画面遷移 / `CupertinoSwitch`・`CupertinoPicker` / `PlatformView`(iOS `UiKitView`・Android `AndroidView` のネイティブのラベル)
- React Native: `FlashList`(`@shopify/flash-list`)/ core の `Modal` / core の `Alert` / `KeyboardAvoidingView`
- Android(View): `Spinner` / `NumberPicker` / `MotionLayout` の遷移 / `Toast`
- iOS(SwiftUI/UIKit): `UICollectionView`(compositional)/ `.fullScreenCover` / `.popover` / `.confirmationDialog`
- CMP: M3 `HorizontalMultiBrowseCarousel` / `NavigationRail` / `BottomSheetScaffold`
