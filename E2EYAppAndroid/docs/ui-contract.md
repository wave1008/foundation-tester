# FT E2EY Android(Views/XML + Material Components)UI 契約

**画面構成・`#id`・表示ラベル・echo は `E2EYAppCMP/docs/ui-contract.md`(唯一の正)と共通**。
このファイルは **この SUT の部品の選択・逸脱・ビルド手順だけ**を定義する。

- applicationId / namespace: `com.ftester.e2ey.android`(Kotlin パッケージ・ディレクトリも `e2ey`)
- 表示名: `FT E2EY Android`・ディープリンクは持たない
- シェル: 単一 Activity + Navigation コンポーネント(`NavHostFragment` + `nav_graph.xml`。画面ごとに Fragment 1つ)+
  `MaterialToolbar`。タイトルの唯一の正は destination の `android:label`(`MainActivity` が `#txt_screen_title` へ写す)
- 動的に生成する行の `#id`(`card_i_jj`・`msg_NN`・`row_l_NN` 等)は View が resource-id を実行時生成できないので、
  `res/values/ids.xml` に静的宣言し、`DynamicIds.of(名前)` で引いて `view.id` へ割り当てる。**行を足したら ids.xml にも足す**
  (宣言漏れは表示時に `check` で落ちる。`msg_NN` だけは宣言数を超えると id 無しになる)
- 追加ライブラリは無し(E2EX と同じ Material 1.12.0 / RecyclerView 1.4.0 / ViewPager2 1.1.0 / coordinatorlayout 1.2.0 / Navigation 2.8.4)

## 画面 → 使った部品

| 画面 | 部品 |
|---|---|
| ホーム | `RecyclerView`(`LinearLayoutManager`)。行に `nav_*` を割り当て |
| A1 入れ子スクロール | 縦の `RecyclerView`(`list_nested`)の行ごとに横の `RecyclerView`(`LinearLayoutManager(HORIZONTAL)`・`RecycledViewPool` 共有)。カードは 140dp × 120dp |
| A2 反転チャット | `RecyclerView` + `LinearLayoutManager(reverseLayout = true)`(アダプタの位置 0 = 最新 = 最下部)。`最新へ` は `FrameLayout` に重ねた `MaterialButton` |
| A3 読み込みの状態 | `ConcatAdapter(RowsAdapter, FooterAdapter)`(Paging の `LoadStateAdapter` 相当を自前)。骨組みの行は同じ `#id`・ラベルで `isEnabled = false` |
| A4 スワイプの操作 | 自前の `SwipeRevealLayout`(reveal 行。`onInterceptTouchEvent` で横の払いを横取り)+ 返信は `ItemTouchHelper`(`SimpleCallback(0, RIGHT)`・閾値 25%) |
| A5 選択モード | `AppCompatActivity.startSupportActionMode`(`ActionMode`)。バーの中身は `customView`(下記)。行は `CheckedTextView` |
| A6 文中リンク | `SpannableString` + `ClickableSpan` + `LinkMovementMethod` |
| A7 PIN と OTP | OTP = 6 つの `TextView`(箱)に重ねた透明な `EditText`(`field_otp`)。PIN = 自前のキーパッド(`MaterialButton` + `ImageButton`) |
| A8 戻るの横取り | `OnBackPressedDispatcher.addCallback(viewLifecycleOwner, …)`(常時有効)。確認は `MaterialAlertDialogBuilder` + 自前の `setView`。結果は `setFragmentResult` |
| A9 引き伸ばせるシート | `CoordinatorLayout` + `BottomSheetBehavior`(`peekHeight` 64dp・`fitToContents = false`・`halfExpandedRatio` 0.5・`hideable = false`)。中のキューは `RecyclerView` |
| A10 スクロールで隠れるバー | 上部 = `AppBarLayout`(`scroll\|enterAlways`)、下部 = `HideBottomViewOnScrollBehavior`、FAB = 自前の `HideFabOnScrollBehavior`(`hide()` / `show()`) |
| A11 折りたたみヘッダとタブ | `CoordinatorLayout` + `AppBarLayout`(縮むヘッダ `scroll\|exitUntilCollapsed` + `TabLayout`)+ `ViewPager2`(ページごとに縦の `RecyclerView`)+ `TabLayoutMediator` |
| A12 高さの揃わないグリッド | `RecyclerView` + `StaggeredGridLayoutManager(2, VERTICAL)`。高さはバインド時に `layoutParams.height` へ設定 |

## 契約からの逸脱(理由付き)

- **`#btn_back` は存在しない**。`MaterialToolbar` の navigationIcon は内部の無名 `ImageButton` で、公開 API から id を
  割り当てられない。contentDescription `戻る` で指す(`tap("戻る")`)
- **`#txt_screen_title` は `MaterialToolbar` の子ではなく `ConstraintLayout` の兄弟**。Toolbar のカスタム子 View にすると、
  値を設定しても木から消える画面があった(E2EX で実測)。表示位置は戻るボタン分の固定マージン
- **A3 のフッタ終端**: 2 回目の「末尾まで送る」も `読み込み中`(1.0 秒)を挟んでから `これ以上ありません` に切り替える
  (契約は挟むかを定めていない)。骨組みの行のシマーのアニメーションは付けていない
- **A4 の `ItemTouchHelper` は返信の行だけ**。reveal 行(ボタンが出て止まる・full swipe)は `ItemTouchHelper` では
  「閾値を越えたら行ごと画面外へ出てから `onSwiped`」の形しか持てず途中で止められないため、自前の `SwipeRevealLayout`
  (子 0 = 左のボタン / 1 = 右のボタン / 2 = 前面の行)。**ボタンは払い始めるまで `GONE` = 木に居ない**。full swipe の閾値は行幅の 60%・
  ボタンが開いたまま止まる閾値はボタン幅の 30%。返信は離した位置が行幅の 25% を越えたら `onSwiped`(速度では確定させない)で、
  描画は 56dp までしか動かさず `notifyItemChanged` で元へ戻す(Signal の返信と同じ作り)
- **A5 のアクションバーは固定領域の下ではなく画面の最上部**(ステータスバーの直下・Toolbar の上)に出る。`ActionMode` の標準の
  置き場所で、echo 領域より上に載る。**`#btn_sel_all` / `#btn_sel_delete` / `#btn_sel_cancel` は `ActionMode` のメニュー項目
  (resource-id を持てない)ではなく `customView` の中のボタンに付けた**。`#btn_sel_cancel` はアイコンだけの `ImageButton`(説明 `キャンセル`)。
  システムの戻るも `ActionMode` を閉じる(選択は捨てる)
- **A5 の選択状態は `CheckedTextView` の checked**(`isChecked`)。行頭のチェックの印は選択モードの間だけ出す
- **A6 の `#row_with_link`**: `TextView` は ClickableSpan を押しても View 自身のクリックも撃つので、押下位置が span 上なら
  行本体の echo(`link=row`)を撃たないよう `OnTouchListener` で位置を判定している。**文字は 14sp**(行の中心がリンクの `こちら` の外に来るため)。
  `#txt_terms` は上に 24dp のパディングを足し、段落の中心が 2 行目(リンクでない側)に来る
- **A7 の `#pin_dots` は空のとき text が空**(`importantForAccessibility=yes` を明示)。OTP の箱は表示専用で、押すと上に重ねた透明な `field_otp` が
  タップを受けて焦点が移る(箱はタップを受けない)
- **A8 の確認ダイアログは `AlertDialog` の標準ボタンではなく自前の `setView`**(標準のボタンには id を付けられない。`#txt_discard_title` /
  `#btn_discard` / `#btn_keep` が要るため)。戻るのコールバックは常時有効で、パネル → 確認 → 素通し(`popBackStack`)の順で扱う。
  **入力のあとは IME が最初の back を消費する**ので、シナリオは `hideKeyboard()` を挟む
- **A9 のシート**: ミニプレーヤー(64dp)は常に先頭に居て、半分・全開では見出し(`#txt_player_title`)とキューがその下に出る。
  畳んだ状態でキューを木に残すか(画面外に clip されたノードが a11y に出るか)は未確認
- **A10 の `bars=hidden`** は上部バー(`AppBarLayout`)が完全に隠れた状態(スクロールが止まった時点)。`snap` は付けていない
  (途中で止まると `shown`)。FAB は `hide()` のアニメーションの後 `GONE`(木から消える)。**FAB の隠れるきっかけは `dyConsumed`**
  なので、上部バーが先に畳まれている間(`RecyclerView` が消費していない送り)は FAB はまだ隠れない
- **A11 のヘッダは `CollapsingToolbarLayout` ではなく素の `LinearLayout`(`scroll|exitUntilCollapsed`)**。`CollapsingToolbarLayout` は
  `android:minHeight` が無いと床が決まらず、pin した子ごと `AppBarLayout` が高さ 0 まで畳まれて木から消える(E2EX の実測)罠があるが、
  この画面ではタブ列がスクロールフラグ無しで残るので `AppBarLayout` は 0 にならない。ヘッダは縮み切ると見えなくなる(床 0)。
  `#tab_posts` / `#tab_media` / `#tab_likes` は `TabLayout.Tab.view`(公開フィールド)に `id` を付けた
- **A12 のタイルは `GAP_HANDLING_MOVE_ITEMS_BETWEEN_SPANS`(既定)**: スクロール中に列間でタイルが入れ替わることがある

## ビルド

```sh
cd E2EYAppAndroid
./scripts/build-android.sh    # → dist/android/ft-e2ey-android-debug.apk
```
