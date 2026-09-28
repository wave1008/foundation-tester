# FT E2EX Android(Views/XML + Material Components)UI 契約

**画面構成・`#id`・表示ラベルは `E2EXAppCMP/docs/ui-contract.md`(唯一の正)と共通**。
このファイルは **Views/XML + Material Components 実装固有の差分だけ**を定義する。

- applicationId / namespace: `com.ftester.e2ex.android`
- 表示名: `FT E2EX Android`
- ディープリンク: 持たない
- シェル: 単一 Activity + Navigation コンポーネント(`NavHostFragment` + `nav_graph.xml`。
  画面ごとに Fragment 1つ)+ `MaterialToolbar`

## 画面ごとの部品

| 画面 | 部品 |
|---|---|
| シェル | `MaterialToolbar` の帯に重ねた `TextView`(`#txt_screen_title`。下記の逸脱参照)。戻るは Toolbar の navigationIcon |
| ホーム | `RecyclerView`(行に `nav_*` を動的割り当て) |
| ページャ | `ViewPager2`(`RecyclerView.Adapter` で5ページ) |
| ボトムシート | `BottomSheetDialogFragment`(選択肢3 + `RecyclerView` 30行) |
| メニュー | `PopupMenu` + `TextInputLayout`(ExposedDropdownMenu)+ `MaterialAutoCompleteTextView` |
| 日付ピッカー | `MaterialDatePicker`(選択 2026-01-15 UTC) |
| ドロワー | `DrawerLayout` + `NavigationView` |
| 引っ張って更新 | `SwipeRefreshLayout` + `RecyclerView`(20行) |
| スナックバー | Material `Snackbar`(`setDuration` で 10000ms / 4000ms を明示) |
| グリッド | `RecyclerView` + `GridLayoutManager(3)`(90セル) |
| スワイプで削除 | `RecyclerView` + `ItemTouchHelper`(LEFT のみ許可) |
| タブ | `TabLayout`(fixed 3 + scrollable 12。カスタム tab view)+ `BottomNavigationView` |
| アニメーション | `TransitionManager` + `Fade`(1500ms)/ `TextSwitcher`(slide 800ms) |
| ツールチップ | `TooltipCompat` + 自前 `PopupWindow`(下記の逸脱を参照) |
| チップと分割ボタン | `Chip`(filter/assist)/ `MaterialButtonToggleGroup`/ `RangeSlider` |
| 検索バー | `com.google.android.material.search.SearchBar` + `SearchView`(+ `RecyclerView` 候補) |
| 引数付き遷移 | Navigation の `argument`(整数 `id`)。`detailFragment` は自分自身へ遷移して積む |

## 契約からの逸脱(Views/XML 特有。すべて「id が存在しない」方向の逸脱)

- **`#btn_back` は存在しない**。`MaterialToolbar` の navigationIcon は内部の無名 `ImageButton` に
  付き、公開 API から id を割り当てられない。contentDescription `戻る`(`toolbar.navigationContentDescription`)
  で指す。表示可否・押下処理は id 無しでも `MainActivity` が結線済み
- **`#opt_fruit_apple/banana/cherry` は存在しない**。`MaterialAutoCompleteTextView` の候補ポップアップは
  `ListPopupWindow` が生成する無名行なので、ラベル(りんご/バナナ/さくらんぼ)で指す
- **`#menu_item_copy/share/delete` は存在しない**。`PopupMenu` も同じ理由(`ListPopupWindow`)。
  `<menu>` リソースの `android:id` はクリック判定にのみ使う内部値で、行 View には出ない。
  ラベル(コピー/共有/削除)で指す
- **`#btn_date_ok` / `#btn_date_cancel` は存在しない**。`MaterialDatePicker` のボタンは
  ライブラリ内部レイアウトの id(`confirm_button` / `cancel_button`)を持ち、上書きできない。
  ラベル `OK` / `キャンセル`(`setPositiveButtonText`/`setNegativeButtonText` で明示設定)で指す。
  日付セルはそもそも契約側も testTag 無し(ラベル前提)
- **`#suggestion_apple/apricot/banana` の一致は語そのもの**(apple/apricot/banana)で contract と同じ。
  ただし RecyclerView の行は表示中の候補だけが存在するため、絞り込みで消えている語は木に無い
- **`#txt_screen_title` は `MaterialToolbar` の子ではなく ConstraintLayout の兄弟**(実機実行で発見:
  Toolbar のカスタム子 View として置くと、値を設定しても木から丸ごと消える画面があった。
  `Toolbar.LayoutParams` の gravity バケット判定・content inset の計算に幅の決定を委ねず、
  ConstraintLayout で Toolbar の帯へ直接重ねて幅・高さを確定させている。表示位置(戻るボタン分の
  固定マージン)は変わらないので、契約上の見え方・`#id` は変わらない
- **`#field_search` は畳まれている間の `SearchBar` を指す**(展開後の `SearchView` の実入力欄では
  ない)。`SearchView` は表示中も `SearchBar` を `GONE` にしない(Material の実装)ため、同じ id を
  両方に付けると展開中に2要素が同じ id を名乗る衝突になる。展開後の実入力欄は
  `#field_search_input`(Android だけの id。契約側には無い)。**通常のシナリオはこれを使わなくてよい**
  —— `tap("#field_search")` で `SearchView.show()` が実入力欄へフォーカスを移すので、続く
  ロケータ無し `type(...)` がそのまま拾う(Shirates 伝統の `tap → type` と同じ経路。docs/commands.md
  §`tap(入力欄)` → `type("文字列")`)
- **`#txt_search_result` は他画面と同じ「上部固定」の慣習に合わせ、`AppBarLayout` 内の `SearchBar` の
  すぐ下に置く**(展開時は `SearchView` の下に隠れるが、`hide()` で戻れば再び見える)

## 契約と同じだが実機未検証(id 割り当ての根拠はライブラリの公開 API/実装のみ。デバイス実行未実施)

- **`#tab_a` `#tab_b` `#tab_c` `#stab_01..12`**: `TabLayout.Tab` は `view` フィールドを公開しないため、
  `Tab.setCustomView()` で id 付き `TextView` を差し込む方式にした(公開 API で id を直接張れる
  確実な手段)。タップで選択される標準挙動は Material が保証するが、a11y ツリー上でこの id が
  期待どおり子孫として出るかは実機で未確認
- **`#navbar_home/search/settings`**: `BottomNavigationView` は `menu` リソースの `android:id` を
  そのままアイテム View に使う実装(`NavigationBarItemView`)のはずだが、実機確認はしていない
- **`#drawer_item_inbox/sent/trash`**: `NavigationView` も同様に menu の id を使う想定だが未確認。
  クリック判定(`setNavigationItemSelectedListener`)は id 前提で動くため、押下自体は保証できる

## ツールチップの実装(独自の PopupWindow)

`TooltipCompat.setTooltipText` は OS 標準の `TooltipPopup` を出すが、これは別プロセス/別ウィンドウの
システム描画で内容 View に触れないため `#txt_tooltip` / `#txt_tooltip_state` を持てない。
このアプリは **`TooltipCompat` も併設した上で**、長押しで自前の `PopupWindow`(`res/layout/popup_tooltip.xml`、
中身は id 付き `TextView`)を出す方式にして id を持たせている(2秒後に自動で閉じる)。

## アニメーションの実装

- 表示切替(1500ms フェード): `android.transition.Fade` + `TransitionManager.beginDelayedTransition`
  (プラットフォーム API。追加ライブラリ不要)
- カウンタ(800ms スライド): `TextSwitcher` + `res/anim/slide_in_up.xml` / `slide_out_up.xml`。
  `TextSwitcher` の2つの子 `TextView` に同じ id(`#txt_anim_count`)を割り当てる
  (`ViewAnimator` は非表示側を `GONE` にするため、静止時は常に1つだけが木に残る)

## スナックバーの秒数

Android 標準の `Snackbar.LENGTH_LONG`(約2.75秒)/ `LENGTH_SHORT`(約1.5秒)は契約の
10秒 / 4秒と値が違うため使わない。`Snackbar.setDuration(Int)` に直値(10000 / 4000)を渡す。

## 第2弾の実装(Android)

`E2EXAppCMP/docs/ui-contract-wave2.md` の13画面を Views/XML + Material Components の定番部品で実装する
(SUT 間で共通の契約は前者、Android 固有の実装選択・逸脱はここに書く)。

| 画面 | 部品 |
|---|---|
| 伸縮するヘッダ | 画面ローカルの `CoordinatorLayout` + `AppBarLayout` + `CollapsingToolbarLayout`(`scroll\|exitUntilCollapsed`・`android:minHeight="?attr/actionBarSize"` 必須。下記の逸脱参照)+ `RecyclerView`(`appbar_scrolling_view_behavior`)。`#txt_collapse_result` は `layout_collapseMode="pin"` |
| 貼り付く見出し | `RecyclerView` + 貼り付く見出しの `ItemDecoration`(`StickyHeaderDecoration`。`onDrawOver` で canvas に直接描画) |
| 時刻ピッカー | `MaterialTimePicker`(`TimeFormat.CLOCK_24H`・9:30・`INPUT_MODE_CLOCK`。入力モード切替は内蔵) |
| ダイアログ | `MaterialAlertDialogBuilder`(アラート・入力つき)/ `BottomSheetDialog`(アクションシート代替)/ `DialogFragment`(`STYLE_NORMAL` + 全画面テーマ)/ `Toast` |
| 長押しメニュー | `registerForContextMenu` + `onCreateContextMenu`(`ContextMenu`) |
| 並べ替え | `RecyclerView` + `ItemTouchHelper`(`UP`/`DOWN`。長押しドラッグは既定で有効) |
| 入力の種類 | `TextInputLayout` + `TextInputEditText`(`inputType` / `minLines`)+ `MaterialAutoCompleteTextView`(編集可) |
| FAB | `CoordinatorLayout` + `BottomAppBar`(`app:menu`)+ `FloatingActionButton`(cradle に anchor)+ `ExtendedFloatingActionButton` |
| 展開するリスト | `ExpandableListView` + `BaseExpandableListAdapter` |
| ステッパーと進捗 | `MaterialButton` の +/- + `LinearProgressIndicator`(`ValueAnimator` で2秒)+ `CircularProgressIndicator` |
| 無限スクロール | `RecyclerView` + `OnScrollListener`(末尾検知で0.8秒後に追加読み込み) |
| ピンチで拡大 | 自前 `ImageView` サブクラス(`PinchZoomImageView`。`ScaleGestureDetector` + 簡易パン) |
| 固有部品 | `Spinner` / `NumberPicker` / `MotionLayout`(`androidx.constraintlayout.motion.widget`) |

`docs/ui-contract-wave2.md` からの逸脱(すべて「id が存在しない」方向、または表内の書式で
明記されていない初期値を実装で決めた方向):

- **`#btn_time_ok` / `#btn_time_cancel` は存在しない**。`MaterialTimePicker` のボタンはライブラリ内部
  レイアウトの id を持ち上書きできない(`MaterialDatePicker` と同型の逸脱)。ラベル `OK` / `キャンセル`
  (`setPositiveButtonText`/`setNegativeButtonText` で明示設定)で指す
- **`CollapsingToolbarLayout` に `android:minHeight="?attr/actionBarSize"` が無いと、スクロールで
  `AppBarLayout` が高さ0まで畳まれ `#txt_collapse_result` ごと木から消える**(実機実行で発見)。
  `layout_collapseMode="pin"` は子の位置を固定するだけで、`AppBarLayout` 自身の最小の高さ(床)は
  別に要る。床は pin した子(`#txt_collapse_result`。高さ `?attr/actionBarSize`)と揃えてある
- **`#bar_action_search` / `#bar_action_share` は id で解決できない**。`BottomAppBar` の
  `app:menu` は `showAsAction="always"` を指定していても、FAB のカドル分の余白を差し引いた残り幅で
  すべてオーバーフロー(「その他のオプション」の1アイコン)へ畳まれることがある(実機実行で観測)。
  オーバーフローの行は `PopupMenu`/`MaterialAutoCompleteTextView` の候補行と同じ `ListPopupWindow` の
  無名行なので、直接アイコンとして出ていても畳まれていても id は持てない。ラベル(`検索`/`共有`)で指す
- **貼り付く見出しの「貼り付いている間の見出し」は View ではなく canvas への直接描画**
  (`StickyHeaderDecoration.onDrawOver`)。RecyclerView へ addView しないため a11y ツリーに出ない。
  実物の見出し行(`#hdr_A`…`#hdr_H`)は通常の RecyclerView アイテムとして別に存在し、
  スクロールで通過する間だけ木に載る
- **`#auto_opt_japan/jamaica/jordan` は存在しない**。`MaterialAutoCompleteTextView` の候補は
  `ListPopupWindow` が生成する無名の行(`MenuFragment` の `#opt_fruit_*` と同型の逸脱)。
  ラベル(Japan/Jamaica/Jordan)で指す
- **全画面ダイアログは `windowNoTitle` 等を積んだ専用テーマではなく、`DialogFragment`
  (`STYLE_NORMAL`)+ `windowIsFloating=false` の最小テーマ + `onStart` での `MATCH_PARENT` 明示**
  で実現する(Android にはこれ以外の「全画面ダイアログ」の定番 API が無い)
- **`#fab_extended` は BottomAppBar のカドルに入らない**。カドルへ収まる FAB は1つ(`#fab_add`)だけなので、
  拡張 FAB はカドルの上に独立して浮かせる(両方を同時に見せる構図として採用)
- **`#field_number` 等の echo の初期値は契約に明記が無いため、空/ゼロ相当**(`number=` /
  `password_len=0` / `lines=1` / `focus=none` / `auto=none` / `bottom=`)を実装側で決めた
- **入力の種類の画面は echo をすべて画面上部の固定領域にまとめ、入力欄は下の `NestedScrollView` に
  分離する**(echo が常に木に載っていること = 全体規約の「操作ボタンと echo が同時に木に載る」を、
  `adjustResize` 下でキーボードに隠れる位置にある `#field_bottom` でも満たすための構成)
- **`#zoom_target` は `FrameLayout`(`clipChildren` 既定 true)で包み、拡大後の絵をその枠で切り取る**
  (`PinchZoomImageView` 自身は `scaleX/scaleY` の transform で描画範囲が自分の元の矩形を超えるため、
  切り取りは親 ViewGroup の役目)
- **並べ替えは `ItemTouchHelper.onMove` を都度 swap する定番実装**。ドラッグ中に複数行をまたいだ場合も
  1回のドラッグで最終的な release 位置まで正しく移動する(隣接1回の入替えに留めない)
- **固有部品の `MotionLayout` はボタン駆動の片道遷移**(`OnSwipe` は使わない。契約が求めるのは
  「ボタンで起動」で、ジェスチャ入力は要求されていない)。完了時の echo は契約どおり常に
  `native=motion:end`

## ビルド

```sh
cd E2EXAppAndroid
./scripts/build-android.sh    # → dist/android/ft-e2ex-android-debug.apk
```
