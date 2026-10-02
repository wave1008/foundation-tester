# UI 部品ごとの書き方と癖

Compose Multiplatform・Flutter・React Native・Android(Views/XML)・iOS(SwiftUI)の定番部品を、
シナリオでどう指し・どう操作し・どう確かめるかのまとめです。**エージェント(AI アシスタント)が
シナリオを書くときの知識として使う**ことを想定しています —— 対象アプリの画面に同じ部品があれば、
該当する節を読んでから書いてください。

- 確かめた環境: Compose Multiplatform 1.11(Material3 1.4 相当)・Flutter・React Native 0.86.2
  (New Architecture / Fabric)・Android Views + Material Components・SwiftUI。
  iOS 27 Simulator(hybrid エンジン / XCUITest エンジン)・Android 15 Emulator。確かめたのは 2026-09-28
- 各節の挙動は fleetest 同梱の検証アプリ群(`E2EXAppCMP/` / `E2EXAppFlutter/` / `E2EXAppRN/` /
  `E2EXAppAndroid/` / `E2EXAppIOS/`)と、そのシナリオ(`TestProjects/E2EX-{CMP,Flutter,RN,Android,iOS}/scenarios/`)
  で再現できます(同じ部品の書き方の実例として読めます)。5つのアプリは同じ画面構成・同じ `#id`・
  同じラベル・同じ echo 文字列の契約(`E2EXAppCMP/docs/ui-contract.md` / `ui-contract-wave2.md`)を
  各フレームワークの定番部品で実装したものです
- 各節の表は **CMP / Flutter / RN / Android View / SwiftUI(iOS)** の順に差分を並べます。
  「共通」は表の直前に書いた挙動がそのまま成り立つという意味です
- **iOS ネイティブ(SwiftUI)には、標準のモーダルドロワーとツールチップの定番部品が無い**ため、
  該当する2画面(ドロワー・ツールチップ)を持ちません。対象アプリが独自にドロワー/ツールチップ
  相当を実装している場合は、他フレームワークの列を参考にしてください
- **「現時点の制約」は fleetest 側で未解決の制約**です。書いてある回避策で書いてください

## 全部品に共通すること

### モーダルが開いている間、背後の画面は木から消える

ドロワー・ドロップダウンメニュー・ボトムシート・ポップアップメニューが開いている間、**背後の画面の
要素は木(スナップショット)に載りません**(全フレームワーク・iOS/Android の両方で確認。SwiftUI の
`Menu`/`Picker(.menu)` も同様)。残るのはモーダルの中身と、スクリムの「閉じる」ボタンだけです。

- 背後の結果表示(`#txt_result` 等)は、**モーダルを閉じてから**読む
- 「モーダルの外側を押して閉じる」は背後の要素を指せないので、要素のタップでは書けない
  (書き方は下の「ドロップダウンメニュー」の節)

```swift
tap("#btn_open_drawer")
exist("#txt_drawer_header")          // ○ 開いた証拠はモーダルの中で取る
// select("#txt_state").textIs(...)  // × 背後の要素は開いている間は見つからない
tap("#drawer_item_sent")             // 閉じてから
select("#txt_state").textIs("drawerOpen=false")
```

**現時点の制約**: React Native は `accessible` な祖先(`accessible={true}` な `View`/`Pressable`)の
下を丸ごと1要素へ畳む。この畳み込みは Android では起きず iOS だけで起きるため、`Tooltip` や
`BottomSheetModal` のようにライブラリが既定で `accessible` を立てる部品では**中身の要素が iOS でだけ
木から消える**(下の「ツールチップ」「ボトムシート」の節を参照)。回避策はアプリ側で
`accessible={false}` を渡すことなので、シナリオ側では直せない(対象アプリの実装依存)。

**現時点の制約**: **Flutter の iOS**は、画面にオーバーレイ(`Tooltip`・ダイアログ等)を一度出すと、
**次の画面遷移までその画面の a11y の矩形を 1/画面倍率(iPhone では 1/3)に縮めて申告します**
(Flutter 側の申告)。**既定の iOS エンジン(in-app)は自動で補正する**ので書き方は変わりません。
**XCUITest エンジン**(`iosInappEngine: false`)だけは補正できず、タップが狙った場所と違う位置に
当たります。回避策(XCUITest エンジンのとき): オーバーレイを出した画面では、一度別の画面へ移って
戻ってから次の操作をする。

### アイコンだけのボタンはアクセシビリティのラベルで指す

アイコンだけのボタンは、a11y ラベル(CMP の `contentDescription` / Flutter・RN の
`Semantics`・`accessibilityLabel` / Android View の `contentDescription` / SwiftUI の
`.accessibilityLabel`)で指せます(`tap("Back")` のように)。アイコンの代わりに文字を置いている画面
では、iOS のラベルが文字と**連結される**ことがあります。その場合は `#id` で指すか、部分一致
`*文字列*` で書いてください。

### 横に送る容器は scrollFrame を必ず渡す

`scroll: .right` / `withScrollRight { }` は、指定が無いと**画面の中央**を払います。ページャ(CMP の
`HorizontalPager` / Flutter の `PageView` / RN の `react-native-pager-view` / Android の
`ViewPager2` / iOS の `TabView(.page)`)や横にはみ出すタブ列が画面の中央に無いと、何も動かずに
失敗します。**横の容器を探索するときは、その容器を `scrollFrame:` で指定**してください(容器に
`#id` が必要です)。

```swift
withScrollRight(scrollFrame: "#pager_main") {
    tap("#btn_page_4")
}
```

iOS の in-app エンジンは、RN の `react-native-pager-view`(中身は `UIPageViewController`)を
自分では送れないので、その領域の送りだけ XCUITest の実スワイプに切り替えます(注記 `fell back to XCUITest`)。
書き方は変わりません。

### Android の画面端は OS の「戻る」

ジェスチャーナビゲーションの Android では、**画面の左右の端から始めた横の払いは OS の「戻る」**に
なります(全フレームワーク共通)。払いの始点を画面の端に寄せないでください
(`flickLeftToRight(startMarginRatio:)` を小さくしない。既定のままにする)。

### 戻るボタンの指し方はフレームワークで違う

| フレームワーク | 戻るボタン |
|---|---|
| CMP | `#btn_back`(アイコンだけの `IconButton`)。ラベル(contentDescription)でも押せる |
| Flutter | `#btn_back` と同じ。**iOS はエッジスワイプで戻らないことがある**(下の「画面遷移」参照。この場合はアプリの戻るボタンを使う) |
| RN | **`#btn_back` は無い**。`native-stack` の戻るボタンはネイティブ描画で `testID` を通せない。`back()`(システムの戻る)で操作する |
| Android View | **`#btn_back` は無い**。`MaterialToolbar` の navigationIcon は内部の無名 `ImageButton` なので、ラベル(contentDescription「戻る」相当)で指す |
| SwiftUI(iOS) | **`#BackButton`** という固定 id で指せる。ラベルは前画面のタイトルと同じ文字列(画面が狭いと OS が汎用のラベルに丸めることがある) |

```swift
ios { tap("#BackButton") }
android { tap("戻る") }       // Android View: ラベルで指す(id なし)
```

## ページャ

- 次のページへ: `flickRightToLeft(scrollFrame: "#pager_main")`(1回で1ページ)
- 画面外のページの要素へ: `withScrollRight(scrollFrame: "#pager_main") { tap("#…") }`
- 端まで戻す: `scrollToLeftEdge(scrollFrame: "#pager_main")`(`scrollToRightEdge` も同じ)
- 今のページは、アプリが出しているページ番号の表示で確かめる

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `HorizontalPager`。共通 |
| Flutter | `PageView`。**iOS の in-app エンジンで `withScrollRight` が効かない**(「全部品に共通すること」参照) |
| RN | `react-native-pager-view`。同じく iOS の in-app エンジンで探索不可 |
| Android View | `ViewPager2`。共通 |
| SwiftUI(iOS) | `TabView(.page)`。共通(この SUT はネイティブなので in-app の制約を受けない) |

## ボトムシート

- 開いた証拠はシートの中の要素で取る(背後は木から消える)
- シートの中の長いリスト: `tap("#row_25", scroll: .down)` で届く(シートが伸びてから中が送られる)
- 選択肢を押して閉じる形は全フレームワークで問題なし
- 払って閉じる: **見出しからシートの下のほうの行まで指を動かす**。`swipeBy` は使わない ——
  比率は**対象の大きさに対する割合**で片側 0.9 が上限なので、小さい見出しでは数 pt しか動かない

```swift
swipeElementToElement("#sheet_title", "#row_04", durationSeconds: 0.3)
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `ModalBottomSheet`(既定は半分まで展開)。iOS はスクリムの「閉じる」ボタンでも閉じられる(iOS の木にローカライズされたラベルのボタンが出る。ラベルはロケールで変わるのでスナップショットから採る) |
| Flutter | `showModalBottomSheet(isScrollControlled: true)` + 固定高さ(70%)。**高さの半分を越えて払わないと閉じない**(このアプリの設定値。払う距離が足りないと戻る) |
| RN | `@gorhom/bottom-sheet` の `BottomSheetModal`。**iOS では既定で中身が `accessible=true` の1要素へ畳まれる**(見出し・選択肢・行が消える。アプリ側で `accessible={false}` を渡して回避。Android は畳まれない) |
| Android View | `BottomSheetDialogFragment`。共通 |
| SwiftUI(iOS) | `.sheet` + `.presentationDetents([.medium, .large])`。dismiss 判定はアプリが自前管理 |

## ドロップダウンメニュー / ポップアップメニュー

- 項目は `#id` でもラベルでも押せる
- 項目を押すとメニューは閉じる
- **外側を押して閉じる**: 背後が木に無いので要素では指せません。
  Android は `back()`、iOS は画面の空いた場所を座標で押す

```swift
tap("#btn_open_menu")
android { back() }
ios { tap(x: 200, y: 600) }   // メニューに重ならない空いた場所
notExist("#menu_item_copy")   // 閉じたことを確かめる
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `DropdownMenu`。共通 |
| Flutter | `PopupMenuButton`(`onCanceled` で dismissed)。共通 |
| RN | `react-native-paper` の `Menu`。**Android の戻るボタンはアプリ側で明示的に消費している**(ライブラリの既知の癖で、消費しないと画面ごと戻ってしまう。アプリ側の作りに依存するので、対象アプリでこの癖が無ければメニューを閉じずに画面が戻ることがある) |
| Android View | `PopupMenu`。行は `ListPopupWindow` の無名行なので**ラベルでしか指せない**(`#menu_item_*` は無い) |
| SwiftUI(iOS) | `Menu`。項目に付けた識別子が AX ツリーへ届くかは SwiftUI の公開 API では保証されない。**届かなければラベルで指す**(このアプリでは実測どおり動く前提だが、届かない構成もありうる) |

## 選択式の入力欄(読み取り専用ドロップダウン)

読み取り専用の選択欄は、**選んだ値がどこに出るかがフレームワークごとに違います**。

| フレームワーク | 部品 | 値の場所 |
|---|---|---|
| CMP | `ExposedDropdownMenuBox` | **`.value`**。`.text` は iOS では欄のラベル(例: `果物`)、Android では `nil` |
| Flutter | `DropdownMenu` | id は外側の容器に付き、**選んだ値は内側のノードにだけ出る(iOS)**。**Android の木には値が出ない** |
| RN | `Pressable` + 読み取り専用 `TextInput` | 外側の `View` に `accessibilityValue` で出す実装(アプリ側の作り。フィールド自体の値は iOS で消えることがある) |
| Android View | `MaterialAutoCompleteTextView` | **木に値が出ない**。アプリ自身の echo 表示で確かめる |
| SwiftUI(iOS) | `Picker(.pickerStyle: .menu)` | **選択結果はラベル自体に出る**(例: `果物, バナナ`)。`.value` は無い |

```swift
select("#field_fruit").valueContains("バナナ")   // ○ CMP(両OS)
// Android View / Flutter(Android)は木に値が出ないので、アプリの echo で確かめる
select("#txt_fruit_result").textIs("fruit=banana")
```

**現時点の制約**: Android View の `MaterialAutoCompleteTextView` は候補ポップアップの行にも
id が無い(`ListPopupWindow` の無名行)ので、候補はラベルで選ぶ。Flutter の `DropdownMenu` の
候補も同様に、確実なのはラベル。

## 日付ピッカー

- 日付のセルには `#id` を付けられません。**ラベルで指します**。ラベルはロケールで変わるので、
  候補を `||` で並べます

```swift
tap("*1月20日*||*January 20, 2026*")
tap("OK")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `DatePickerDialog`。OK/キャンセルには `testTag` が付けられる(`#btn_date_ok` / `#btn_date_cancel`) |
| Flutter | `showDatePicker`。**OK/Cancel には id を付けられない**(組み込みダイアログの内部。ラベルは英語の既定のまま)。**`date=null` はこの SUT では再現できない**(未選択に戻す UI が無いため、キャンセル以外は常に選択済みの日付が返る)。緩い一致(`*January 20*`)は見出し「January 2026」にも当たるので、**`*January 20, 2026*` のように年まで含める** |
| RN | `@react-native-community/datetimepicker`。**Android は完全ネイティブダイアログ**で OK/Cancel に `testID` が通らない(ラベルで指す)。`#btn_date_ok` / `#btn_date_cancel` は**iOS の inline モーダルだけ**に存在する |
| Android View | `MaterialDatePicker`。OK/キャンセルはライブラリ内部のボタン(id 上書き不可)で、ラベル(`setPositiveButtonText` 等で明示設定した文字列)で指す |
| SwiftUI(iOS) | `.sheet` + `DatePicker(.graphical)`。iOS の `DatePicker` は必ず値を持つため**`date=null` は発生しない** |

## ドロワー

- ボタンで開く・項目を押して閉じる形は全フレームワークで問題なし
- 開いている間、背後の画面は木から消える(「全部品に共通すること」の節)。
  状態の表示は閉じてから読む
- **払って開く**: `flickLeftToRight()` / 閉じるのは `flickRightToLeft()`。**始点は既定のまま**に
  する —— Android で `startMarginRatio:` を小さく(0.05 など)すると、始点が画面の端に入って OS の
  「戻る」になり、前の画面へ戻ってしまう

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `ModalNavigationDrawer(gesturesEnabled = true)`。共通 |
| Flutter | `Scaffold.drawer` + `Drawer`。共通 |
| RN | `@react-navigation/drawer`。**払って開くのは画面端からのエッジスワイプで、Android のジェスチャーナビゲーションの「戻る」帯と重なる** —— シナリオでは払いに頼らずアプリの開くボタンを使う |
| Android View | `DrawerLayout` + `NavigationView`。同じくエッジスワイプは Android OS の「戻る」帯と重なるため、**シナリオはボタンで開く** |
| SwiftUI(iOS) | **無い**(iOS に標準のモーダルドロワーが無いため、この SUT はこの画面自体を持たない) |

## 引っ張って更新

- 更新させる: 一覧の上の行から下の行へ指を動かす
  (`swipeElementToElement("#row_01", "#row_06", durationSeconds: 0.6)`)
- 更新の完了はアプリの表示(回数・時刻など)で確かめる

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `PullToRefreshBox`。`swipeElementToElement` で反応する |
| Flutter | `RefreshIndicator`。共通 |
| RN | `RefreshControl`。**iOS は `swipeElementToElement` の短い距離では始まらない**(下記) |
| Android View | `SwipeRefreshLayout`。共通(`swipeElementToElement` で反応) |
| SwiftUI(iOS) | `.refreshable`。**`swipeElementToElement` の短い距離(5行ぶん≒260pt)では始まらない**(下記) |

**現時点の制約**:

- **SwiftUI の `.refreshable` と RN の iOS `RefreshControl` は長く引かないと始まりません**(実測
  約470pt。5行ぶん約260pt の `swipeElementToElement` では反応しない)。回避策: 画面比率で
  上から下まで大きく引く生ジェスチャを使う。
  ```swift
  gesture {
      FTFinger(x: 0.5, y: 0.3).move(x: 0.5, y: 0.85, durationSeconds: 1.0).hold(seconds: 0.3)
  }
  ```
- **iOS の XCUITest エンジン**(`iosInappEngine: false`)では、一覧の上端で `scrollToTop()` を
  使うと**更新が1回余分に走ります**(端に着いたことを確かめる送りが「引っ張る」になる。XCUITest は
  容器が「まだ送れるか」を教えないため)。既定の iOS エンジンでは起きない
- **Flutter の iOS でも、`scrollToTop()` で上端へ戻すと更新が走ることがあります**(調査中)
- 回避策はどちらも共通: 更新の回数を検証するシナリオでは、`scrollToTop()` の**後に回数を読まない**
  (回数の検証はそれより前に済ませる)
- Android は全フレームワークで起きません(`scrollToTop()` / `scrollToBottom()` は一覧を
  アクセシビリティのスクロール操作で送るので、端を越えた引っ張りにならない)

## スナックバー / トースト

- 中身には `#id` を付けられません。メッセージもアクションも**ラベルで指します**
  (`exist("Deleted")` / `tap("Undo")`)
- 自然に消えるのを待つ: `waitForClose("Saved", waitSeconds: 10)`
  (短い表示は約4秒・長い表示は約10秒)

| フレームワーク | 部品・差分 |
|---|---|
| CMP | Scaffold の `SnackbarHost`。共通 |
| Flutter | `ScaffoldMessenger.showSnackBar`。共通(duration は秒数を直書き) |
| RN | `react-native-paper` の `Snackbar`。共通 |
| Android View | Material `Snackbar`(`setDuration` に 10000ms / 4000ms を明示指定。既定の LENGTH_LONG/SHORT は使わない) |
| SwiftUI(iOS) | **標準のスナックバー部品が無い**ため自前実装(オーバーレイ)。挙動は共通 |

**すぐ消える部品の確認は視覚検証を外します**: `exist("Deleted", requireVisible: false)`。
テキストの視覚検証は画面を撮って読むので、時間がかかります(並列のレーンが多い・マシンが混んでいる・
プロジェクトの初回実行で OCR を暖機している、のどれでも延びます)。検証が終わる前に部品が消えると、
出ていたのに「見つからない」で失敗します。外した確認は「木に居ること」だけを見ます。

## グリッド

- 画面外のセルは木に居ません。`tap("#cell_86", scroll: .down)` で届く。戻りは `scroll: .up`
- 1行に複数の要素が並んでも、縦の探索はそのまま使える

全フレームワーク共通(CMP `LazyVerticalGrid` / Flutter `GridView.builder` / RN
`FlatList numColumns={3}` / Android View `RecyclerView` + `GridLayoutManager` / SwiftUI
`LazyVGrid`)。

## スワイプで削除

- 行の上で横に払う: `swipeBy("#row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)`。
  比率の上限は片側 0.9
- 無効な向きへ払っても何も起きないこと(行が残ること)も確かめられる

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `SwipeToDismissBox`。払うと直接消える |
| Flutter | `Dismissible(direction: .endToStart)`。払うと直接消える |
| RN | `react-native-gesture-handler` の `Swipeable`。払うと直接消える |
| Android View | `ItemTouchHelper`(LEFT のみ)。払うと直接消える。ツールが払う経路を OS の「戻る」の帯(画面の左右の端)に入らないよう内側へ寄せる |
| SwiftUI(iOS) | `.swipeActions(edge: .trailing, allowsFullSwipe: true)`。**払っただけでは消えず、右端に現れる「削除」ボタンを押す必要がある**(iOS の定番の見せ方)。**iOS 26 以降は、leading 側に何も登録していない行を右へ払うと画面が戻ることがある**(コンテンツの上の右払いも OS の「戻る」になる。実測で 12 回に 1 回)。「無効な向きは何も起きない」を確かめるなら、アプリ側がその画面でこのジェスチャを切っている必要がある |

```swift
// SwiftUI(iOS)だけ、払った後にボタンを押す
swipeBy("#swipe_row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)
ios { tap("<削除ボタンのラベル。スナップショットから採る>") }
```

## タブ(固定・横スクロール・ナビゲーションバー)

- 固定のタブは `#id` でもラベルでも押せる
- 横にはみ出すタブ列は、**タブ列に `#id` を付けて `scrollFrame:` に渡す**
  (`withScrollRight(scrollFrame: "#stab_row") { tap("#stab_11") }`)
- 下部ナビゲーションバーの項目はラベル(アイコンの下の文字)で押せる

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `PrimaryTabRow` / `ScrollableTabRow` / `NavigationBar`。共通 |
| Flutter | `TabBar` / `TabBar(isScrollable: true)` / `NavigationBar`。**タブのラベルに「Tab 3 of 3」のような文言が付く**ため、完全一致ではなく**部分一致 `*タブC*` で指す** |
| RN | `material-top-tabs` / `bottom-tabs`。**ラベルに「tab, 2 of 3」が付く**ため同様に部分一致で指す。3つの Navigator(固定タブ・横スクロールタブ・下部ナビゲーションバー)が兄弟として並ぶ画面は、react-navigation の制約(1つの親画面に Navigator は1つまで)を `NavigationIndependentTree` で回避しているアプリ実装の詳細で、シナリオの書き方には影響しない |
| Android View | `TabLayout`(fixed + scrollable)/ `BottomNavigationView`。共通 |
| SwiftUI(iOS) | 固定タブは `Picker(.segmented)`、横スクロールタブは横 `ScrollView` のボタン列、下部は埋め込み `TabView`。**下部ナビゲーションバーの識別子が実際のタブボタンまで届くかは iOS バージョン依存で不安定** —— 届かない場合はラベルで指す |

## アニメーション(フェード・切り替え)

- フェードで出る要素も `select("#…").textIs("…")` でそのまま読める(読めるようになるまで待たれる)
- 消えるのを待つ: `waitForClose("#…", waitSeconds: 5)`
- 切り替えアニメーション中に続けて押しても、最後の値が読める

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `AnimatedVisibility`(非表示で composition から外れる = 木から消える)/ `AnimatedContent` |
| Flutter | `AnimatedOpacity`(**非表示でも要素は木に残ったまま透明度だけ動く**。CMP と違い要素の有無では判定できないので、**表示状態は echo(`visible=true/false`)で確かめる**)/ `AnimatedSwitcher` |
| RN | `react-native-reanimated` の `FadeIn`/`FadeOut`。**カウンタ切り替えは `key` によるコンポーネントの再マウント方式**なので、切り替え中は新旧2つの要素が一瞬同時に木へ乗ることがある(CMP の `AnimatedContent` と同じ特性) |
| Android View | `Fade`(`TransitionManager`)/ `TextSwitcher`。共通 |
| SwiftUI(iOS) | `withAnimation` + `.transition(.opacity)` / `.contentTransition(.numericText())`。共通 |

**現時点の制約**: Flutter の `AnimatedOpacity` は非表示化しても要素を木から消さないため、
「要素が無いこと」を可視性の根拠にしないでください。この画面に限らず、Flutter でフェードによる
表示切り替えを検証するときは、アプリが出す状態の echo(または `checkIsON`/`checkIsOFF` が使える
部品ならそちら)で判定してください。

## ツールチップ

- アンカーを長押しする: `tap("#btn_info", holdSeconds: 1.0)`
- **押している間だけ出る**ツールチップは、押している間に検証する:
  `hold("#btn_info", holdSeconds: 3) { select("#txt_tooltip").textIs("…") }`

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `TooltipBox` + `PlainTooltip`。iOS は離した後もしばらく出ている。**Android は押している間だけ出る**ので `hold { }` の中で検証する(文字も木で読める) |
| Flutter | `Tooltip(triggerMode: longPress)`。吹き出し本文に id を付けられないためラベルで指す。**表示中かどうかの状態は近似値**(表示イベントから固定の表示秒数だけ待って hidden とみなす実装で、非表示アニメーション完了の直接観測ではない) |
| RN | `react-native-paper` の `Tooltip`。**`accessible` な祖先がアンカー(`IconButton`)を1要素へ畳むため、アンカー自身に付けた識別子は iOS で木から消える**(Android は畳まない)。アプリ側はより外側の `View` にアンカーの識別子を持たせて回避している。**吹き出しは押している間だけ表示され、指を離すと消える**ので、`hold("#anchor", holdSeconds: 3) { … }` のブロックの中で検証する(`tap(holdSeconds:)` は離してから検証するので確認できない) |
| Android View | `TooltipCompat` 標準ポップアップは別プロセス描画で内容を読めない。自前の `PopupWindow`(フォーカスを取らない別ウィンドウ)も**文字は木に載らない**。出ていることは、`hold { }` の中でアプリが出す状態の表示で確かめる |
| SwiftUI(iOS) | **無い**(iOS の長押しはコンテキストメニューに倒れる慣用のため、この SUT はこの画面自体を持たない) |

`tap(holdSeconds:)` は指を離してから次の行へ進むので、押している間だけ出る部品は次の行では
既に消えています。`hold { }` はブロックの中身を指が下がっている間に実行します。

## チップと分割ボタン

- FilterChip / SegmentedButton の選択状態は `checkIsON()` / `checkIsOFF()` で読める
- RangeSlider(範囲スライダー)のつまみには `#id` を付けられません。値はアプリが出している
  表示で確かめる

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `FilterChip` / `AssistChip` / `SegmentedButtonRow` / `RangeSlider`。共通 |
| Flutter | `FilterChip` / `ActionChip` / `SegmentedButton` / `RangeSlider`。共通 |
| RN | `react-native-paper` の `Chip` / `SegmentedButtons`。**両端つまみの単一レンジスライダー部品が無い**ため、`#range_slider` は2本の独立した Slider(`#range_slider_min` / `#range_slider_max`)をまとめる箱として存在する。操作対象はこの2つ |
| Android View | `Chip`(filter/assist)/ `MaterialButtonToggleGroup` / `RangeSlider`。共通 |
| SwiftUI(iOS) | `Toggle(.toggleStyle(.button))` / `Button(.bordered)` / `Picker(.segmented)`。**範囲スライダーの標準部品が無いため `RangeSlider` 相当は省略**(結果表示だけが固定値で存在し、対応する操作可能な部品は無い) |

## 検索バー

- 入力欄を押して `type("…")`、候補を `#id` で押す

```swift
tap("#field_search")
type("...")   // または type(".textField", "...") で入力欄を型で指す
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | Material3 `SearchBar`。**iOS の入力欄は入力文字の代わりに説明文を値として出す**(`select(...).valueIs(…)` では入力を確かめられないので、候補や確定後の結果で確かめる。ツールは画面の OCR で入力を確かめるので `type` 自体は重複せず通る) |
| Flutter | `SearchAnchor.bar`。**バーを押すと `#id` の無い別の入力欄が開く**。開いた欄は型セレクタ(`type(".textField", "...")`)で指す必要がある(fleetest はフォーカスが別の欄へ移った状態での二重入力を防ぐため、ロケータ無しの `type` を拒否する) |
| RN | `react-native-paper` の `Searchbar`。共通(1つの入力欄がそのまま検索欄) |
| Android View | `com.google.android.material.search.SearchBar` + `SearchView`。**`#field_search` は畳まれている間のバーを指す**(展開後の実入力欄は別 id `#field_search_input` だが通常は使わなくてよい —— `tap("#field_search")` が展開後の実入力欄へフォーカスを移すので、続くロケータ無しの `type(...)` がそのまま拾う) |
| SwiftUI(iOS) | `.searchable`。**`#field_search` は存在しない**(`.searchable` が出す検索欄に識別子を渡す公開 API が無いため)。プレースホルダ文字列で指す |

## 画面遷移(ナビゲーション)

- 引数付きの遷移・積み重ね・アイコンだけの戻るボタンは全フレームワークで問題なし
- `back()` は Android では OS の戻る、iOS ではエッジスワイプで1画面戻る(navigation-compose /
  go_router / react-navigation / Navigation コンポーネント / NavigationStack、いずれも共通)

| フレームワーク | 部品・差分 |
|---|---|
| CMP | navigation-compose の `NavHost`。共通 |
| Flutter | `go_router`。**iOS はエッジスワイプで戻らないことがある**(合成したエッジスワイプが `MaterialPage` の戻りを起こさない。始点・時間を変えても再現)。回避策: iOS ではアプリの戻るボタン(`#btn_back`)を使い、Android だけ OS の `back()` を使う |
| RN | `@react-navigation/native-stack`。共通(戻るは常にシステムの `back()` かネイティブの戻るボタン) |
| Android View | Navigation コンポーネントの `NavHostFragment`。**現時点の制約**: 詳細画面を複数積んだ状態でツールバーの戻る(ラベル「戻る」)を押しても1つ戻らないことがある(調査中)。回避策: 複数階層を検証するシナリオでは、ツールバーのタップではなく OS の `back()` を使う |
| SwiftUI(iOS) | `NavigationStack`。戻るボタンは固定 id `#BackButton` |

## 伸縮するヘッダ

展開時は大きな見出しを表示し、下へスクロールすると縮む TopAppBar/AppBar 系の部品です。

| フレームワーク | 部品・差分 |
|---|---|
| CMP | 画面ローカル `Scaffold` + `LargeTopAppBar` + `exitUntilCollapsedScrollBehavior()`。ルートの `TopAppBar` も残ったまま二重に表示される契約なので、`#txt_screen_title` はそちらで読める |
| Flutter | `CustomScrollView` + `SliverAppBar(pinned, expandedHeight)` + `SliverList`。共通 |
| RN | `Animated.FlatList` + `useAnimatedScrollHandler` によるスクロール連動ヘッダ(別レイヤーで重ねる自前実装)。共通 |
| Android View | `CoordinatorLayout` + `AppBarLayout` + `CollapsingToolbarLayout`。共通 |
| SwiftUI(iOS) | `List` + `.navigationBarTitleDisplayMode(.large)`。**実際に伸縮するシステムの大見出し自体には識別子が付かない**(戻るボタンと同じ理由で UINavigationBar の内部描画に公開 API が無い)。契約の「大きな見出し」相当は別要素として置かれ、`#txt_collapse_result` は縮小後も木に残る固定位置に置かれている |

行を押すと echo が出る点・echo が縮んでも木に残る位置に置かれている点は全フレームワーク共通です。

## 貼り付く見出し

セクションの見出しがスクロールしても上端に貼り付く一覧です。

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `LazyColumn` の `stickyHeader`。共通 |
| Flutter | `SliverPersistentHeader(pinned)` をセクションごとに `SliverMainAxisGroup` でまとめる(単純に並べるだけだと複数の見出しが同時に貼り付くため) |
| RN | `SectionList`(`stickySectionHeadersEnabled`)。**次のセクションの見出しが上端に来るタイミングで、そのセクションの先頭行に見出しの高さぶん重なる**(貼り付く見出しを持つリスト実装に共通の挙動で RN 固有ではない)。**見出しに潜った行を `tap` するときは、fleetest が見出しの外まで送ってから押す**(注記 `scrolled the container to bring the target out from under #hdr_… before touching it`)ので書き方は変わらない |
| Android View | `RecyclerView` + 貼り付く見出しの `ItemDecoration`。**貼り付いている間の見出しは canvas への直接描画で a11y ツリーに出ない**。実物の見出し行は通常のリストアイテムとして別に存在し、スクロールで通過する間だけ木に載る |
| SwiftUI(iOS) | `List(.plain)` + `Section(header:)`。plain スタイルの Section 見出しは標準で上端に貼り付く |

## 時刻ピッカー

- 確定 / キャンセルを押す。付けられなければラベルで指す

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `AlertDialog` + `TimePicker`/`TimeInput`。`#btn_time_ok` / `#btn_time_cancel` は `testTag` 付き |
| Flutter | `showTimePicker`。**OK/Cancel には id を付けられない**(組み込みダイアログの内部。英語の既定ラベルのまま) |
| RN | `@react-native-community/datetimepicker`(`mode="time"`)。Android はネイティブ `TimePickerDialog`(入力モード切替アイコンを既定で持つ)、iOS は `display="spinner"` を自前 Modal(OK/キャンセル付き)に載せる。**iOS 側にだけ入力モードへの切替口が無い** |
| Android View | `MaterialTimePicker`。**`#btn_time_ok` / `#btn_time_cancel` は存在しない**(ライブラリ内部レイアウトの id を上書きできない)。ラベル(`OK`/`キャンセル`)で指す |
| SwiftUI(iOS) | `.sheet` + `DatePicker(.wheel, .hourAndMinute)`。共通 |

## ダイアログ(アラート・入力つき・アクションシート・全画面・トースト)

| `#id` | 種類 | 結果 |
|---|---|---|
| `#btn_alert` | 確認アラート(OK/キャンセル) | `alert=ok` / `alert=cancel` |
| `#btn_prompt` | 入力欄つき(`#field_prompt`) | `prompt=<入力>` / `prompt=cancel` |
| `#btn_action_sheet` | アクションシート | `sheet=camera` / `sheet=library` / `sheet=cancel` |
| `#btn_fullscreen` | 全画面ダイアログ | `fullscreen=saved` / `fullscreen=closed` |
| `#btn_toast` | OS のトースト | `toast=shown` |

```swift
tap("#btn_alert")
tap("OK")
select("#txt_dialogs_result").textIs("alert=ok")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `AlertDialog` / `ModalBottomSheet`(アクションシート代替)/ `Dialog(usePlatformDefaultWidth = false)`。**トーストは実装しない**(commonMain に定番部品が無い) |
| Flutter | `AlertDialog` / `showCupertinoModalPopup` + `CupertinoActionSheet` / `Dialog.fullscreen`。**アラート/入力つき/アクションシートの内部ボタンには id が無い**(ラベルで指す)。**トーストは実装しない**(Android の `Toast` 相当の OS 標準 API が iOS に無いため) |
| RN | `Alert.alert` / `react-native-paper` の `Dialog` + `TextInput`(両 OS 共通実装)/ iOS `ActionSheetIOS` + Android `Dialog`+`List.Item`(代替)/ core `Modal`(全画面。`SafeAreaView` で自前にセーフエリアを避ける)/ Android だけ `ToastAndroid`。**`#btn_toast` は Android にしか存在しない** |
| Android View | `MaterialAlertDialogBuilder` / `BottomSheetDialog`(アクションシート代替)/ `DialogFragment`(全画面)/ `Toast` |
| SwiftUI(iOS) | `.alert` / `.alert` + `TextField` / `.confirmationDialog` / `.fullScreenCover`。**`#btn_toast` は省略**(iOS に OS 標準のトーストが無い。前述のスナックバー画面の自前 toast とは別物) |

## 長押しメニュー(コンテキストメニュー)

- 行を長押しして選ぶ: `tap("#ctx_row_2", holdSeconds: 1.0)` → `tap("複製")`

```swift
tap("#ctx_row_2", holdSeconds: 1.0)
tap("複製")
select("#txt_context_result").textIs("context=row2:copy")
```

全フレームワーク共通の書き方です(CMP `combinedClickable(onLongClick)` + `DropdownMenu` /
Flutter `onLongPressStart` + `showMenu` / RN `Pressable(onLongPress)` +
`react-native-paper` の `Menu` / Android View `registerForContextMenu` / SwiftUI
`.contextMenu`)。メニューは別ウィンドウなので、モーダル共通の規律(背後が木から消える)が
そのまま当てはまります。

## 並べ替え(ドラッグ)

- 長押ししてから指を離さずに動かす(タップ+移動では書けない・`gesture` でしか書けない)
- **着地位置はフレームワークで前後します**(何行ぶん動かすと1行進むかの判定が部品ごとに違う)。
  厳密な着地行を assert せず、「動いたこと」を確かめる

```swift
// 座標は #reorder_row_1 の枠に対する比率。y=2.5 = 2行ぶん下(行の高さが揃っている前提)
gesture("#reorder_row_1") {
    FTFinger(x: 0.5, y: 0.5).hold(seconds: 0.8)
        .move(x: 0.5, y: 2.5, durationSeconds: 1.0)
        .hold(seconds: 0.3)
}
// 同じ 2 行ぶんの移動で CMP・Flutter は1つ下、RN は末尾まで動く(部品ごとの感度の違い)
select("#txt_reorder_result").textMatches("^order=2,")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | 定番コンポーネント無し(`detectDragGesturesAfterLongPress` の自前実装。**離した位置ではなく、しきい値を跨いだ時点で1スロットずつ即座に確定する** = 動かす量にほぼ比例して進む) |
| Flutter | `ReorderableListView`(既定のドラッグハンドル)。指を離した位置がそのまま最終順序になる |
| RN | 定番の外部ライブラリを使わず `Gesture.Pan().activateAfterLongPress()` の自前実装。しきい値(行の高さの半分)を跨ぐたびに並べ替えるので、**指を離した位置までまとめて動く**(2行ぶんの移動で末尾まで動くことがある) |
| Android View | `ItemTouchHelper`。ドラッグ中に複数行をまたいでも、1回のドラッグで最終的な release 位置まで正しく移動する |
| SwiftUI(iOS) | `List` + `.onMove` + 常時編集モード(`.environment(\.editMode, .constant(.active))`)。右端のハンドルを掴んでドラッグする |

## 入力の種類

**echo は画面上部の固定領域(スクロールしない・キーボードに隠れない位置)にまとまっています**。

| `#id` | 種類 | echo |
|---|---|---|
| `#field_number` | 数字キーパッド | `number=<値>` |
| `#field_password` | パスワード | `password_len=<文字数>` |
| `#field_multiline` | 複数行 | `lines=<行数>` |
| `#field_first` → `#field_second` | IME の「次へ」 | `focus=second` |
| `#field_auto` | オートコンプリート | `auto=Japan` |
| `#field_bottom` | 画面下端(キーボードに隠れる) | `bottom=<値>` |

```swift
type("#field_number", "123")
select("#txt_number_echo").textIs("number=123")

type("#field_first", "山田")
pressEnter()
select("#txt_focus_echo").textIs("focus=second")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `OutlinedTextField` + `ExposedDropdownMenuBox`(編集可)。**iOS はキーボードが出ると既定で画面全体が押し上げられる**(`OnFocusBehavior.FocusableAboveKeyboard` が既定。画面上部に固定したテキストが画面外へ出ることがある。アプリ側で `DoNothing` を設定すれば起きない) |
| Flutter | `TextField` + Material `Autocomplete<String>`。数字キーパッド欄は `FilteringTextInputFormatter.digitsOnly` で数字以外を弾く(`keyboardType: number` だけでは物理キーボード等からの非数字入力を防げないため) |
| RN | `react-native-paper` の `TextInput` + 自前の前方一致候補リスト。日本語ロケール端末の既定キーボードがローマ字→仮名変換を行うため、英字専用欄は `autoCorrect={false}` + `keyboardType="ascii-capable"` 等で素の英字キーボードにする(アプリ側の対処) |
| Android View | `TextInputLayout` + `TextInputEditText` + `MaterialAutoCompleteTextView`(編集可)。**オートコンプリートの候補行に id が無い**(`ListPopupWindow` の無名行。ラベルで指す) |
| SwiftUI(iOS) | `TextField`(`.numberPad` / `.vertical` axis)/ `SecureField` + `@FocusState`。**オートコンプリートの候補は iOS だけで検証**(Android は候補ウィンドウが a11y の木に出ないため。下記) |

- **オートコンプリートの候補は、打った後に遅れて出ます**(非同期)。候補を押すときは出るまで待ちます。
  待たないと、遅い機械でだけ「候補が見つからない」で落ちます。

  ```swift
  type("#field_auto", "Ja")
  tap("#auto_opt_japan", waitSeconds: 5)
  ```

**現時点の制約**:

- **Android(全フレームワーク共通)は非フォーカスのポップアップウィンドウの中身が木に出ないことがあります**。
  Android の a11y の木の根は「アクティブウィンドウ1枚だけ」(`getRootInActiveWindow()`)なので、
  フォーカスを取らないポップアップ(オートコンプリートの候補一覧など)は木に載らない画面がある。
  **`Spinner`/`ExposedDropdownMenuBox` のようにフォーカスを持つポップアップの候補は表示されるように
  なった**(ブリッジ v75)。**ツールチップ・一部のオートコンプリート候補は依然として非表示**。
  回避策: 候補を直接検証できないときは、アプリ自身の echo で確定後の値を確かめる
- **Android は一部の入力欄で `ACTION_SET_TEXT` を拒否します**(Material の `SearchView`・
  一部の Flutter の入力欄で確認)。回避策は無く、`type` は既定の打鍵で入力する(拒否されるのは
  a11y 経由の一括書き込みだけで、通常の `type` の打鍵は通る)
- **React Native の iOS(in-app エンジン)で、欄の直下に出る候補を押せないことがあります**(調査中)。
  `pressEnter()` の後もキーボードが残り、その下の候補がキーボードに隠れたままになる。回避策: 候補が
  キーボードに隠れない位置に出る画面構成にするか、確定後の値をアプリ自身の echo で確かめる

## FAB(フローティングアクションボタン)

- FAB はリストの上に浮かぶ(リストの行を覆う位置)。下端の行へは通常のスクロール探索で届く
- **下のバーを一覧に重ねるレイアウトでは、一覧の下に余白が無いと末尾の行がバーの下から出てこず、`exist` が「見えない」で落ちます**(アプリ側の作り。Android View は `RecyclerView` に `clipToPadding="false"` + `paddingBottom`、RN はバーを `position: absolute` にせず一覧の下に並べる)

```swift
tap("#fab_add")
select("#txt_fab_result").textIs("fab=add")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | 画面ローカル `Scaffold` の `floatingActionButton` + `bottomBar`(`BottomAppBar`)。共通 |
| Flutter | `Scaffold.floatingActionButton`(`FloatingActionButton` + `.extended`)+ `BottomAppBar`。**同一画面に複数の FAB を置くとき、`heroTag` の衝突に注意が要る**のはアプリ実装側の話でシナリオには影響しない |
| RN | `react-native-paper` の `FAB` + `AnimatedFAB` + `Appbar`。共通 |
| Android View | `CoordinatorLayout` + `BottomAppBar` + `FloatingActionButton`。**FAB の切り欠き(カドル)の分だけ幅が足りず、BottomAppBar の項目が「その他のオプション」へ畳まれることがあります**(下記) |
| SwiftUI(iOS) | iOS に FAB の定番が無いため overlay の `Button` + `.toolbar(placement: .bottomBar)` で自作。共通 |

**現時点の制約**: Android(View)の `BottomAppBar` は、FAB のカドル分の余白を差し引いた残り幅が
足りないと項目を「その他のオプション」の1アイコンへ畳みます。畳まれた行は `ListPopupWindow` の
無名行なので id を持てません。回避策:

```swift
tap("その他のオプション")   // 畳まれていたら先にオーバーフローを開く
tap("検索")
```

## 展開するリスト

- グループを押して開き、子を選ぶ

| フレームワーク | 部品・差分 |
|---|---|
| CMP | `AnimatedVisibility` の開閉。共通 |
| Flutter | `ExpansionTile`。**`title` 単体にだけ id を付ける**(`ExpansionTile` 全体に付けると開いた子までまとめて1ノードに畳まれる Compose の Slider と同種の罠。子は個別に id が付いているので操作には影響しない) |
| RN | `react-native-paper` の `List.Accordion` + `List.Item`。共通 |
| Android View | `ExpandableListView`。共通 |
| SwiftUI(iOS) | `DisclosureGroup`(List 内)。既定で閉じる |

## ステッパーと進捗

- +/- ボタンで数量を増減。進捗バーは決定的に2秒で 0→100% になる
- 不定の回転インジケータは進行中だけ表示される

```swift
tap("#btn_qty_plus")
select("#txt_qty").textIs("qty=2")

tap("#btn_start_progress")
select("#txt_progress").textIs("progress=running")
select("#txt_progress", waitSeconds: 3).textIs("progress=done")
```

| フレームワーク | 部品・差分 |
|---|---|
| CMP | +/- ボタン + `LinearProgressIndicator`(`Animatable`)+ `CircularProgressIndicator`。共通 |
| Flutter | `IconButton` ×2 + `AnimationController` 駆動の `LinearProgressIndicator` + `CircularProgressIndicator`。共通 |
| RN | `react-native-paper` の `IconButton` + `ProgressBar` + `ActivityIndicator`(`requestAnimationFrame` で決定的に刻む)。共通 |
| Android View | `MaterialButton` の +/- + `LinearProgressIndicator`(`ValueAnimator`)+ `CircularProgressIndicator`。共通 |
| SwiftUI(iOS) | `Stepper` / `ProgressView(value:)` / `ProgressView()`。**+/- 専用のボタン(`#btn_qty_plus`/`#btn_qty_minus`)は存在しない** —— `Stepper` 本体に +/- が一体化しており、`#<id>-Increment` / `#<id>-Decrement` というシステム標準のラベルで表面化する |

```swift
// SwiftUI(iOS)だけ、+/- は Stepper 本体の子として現れる
ios { tap("#stepper_qty-Increment") }
```

## 無限スクロール

- 末尾近くまで送ると自動で次の分を読み込む。読み込み中は末尾に読み込み中の表示が出る
- 遠い行へは `maxSwipes:` を増やして届かせる

```swift
tap("#row_i_57", scroll: .down, maxSwipes: 30)
select("#txt_infinite_result").textIs("infinite=row_i_57")
```

全フレームワーク共通(CMP `snapshotFlow` による末尾検知 / Flutter `ScrollController` リスナー /
RN `onEndReached` / Android View `OnScrollListener` / SwiftUI 末尾行の `.onAppear`)。

**現時点の制約**: RN の `FlatList` の `onEndReached` は、初期データが1画面に収まっているだけで
(1度もスクロールしていなくても)発火することがあります(アプリ側は実際にスクロールを始めたことを
控えてから読み込む対処をしていますが、この対処が無いアプリでは開いた直後に複数ページぶん
まとめて読み込まれることがあります)。シナリオ側での回避策は無く、初期読み込み件数を厳密に
assert する場合はアプリの対処に依存することを踏まえてください。

**アプリの作りによる癖(Android View)**: 読み込みが終わったときに一覧を**丸ごと更新**する作り
(`RecyclerView` の `notifyDataSetChanged()`)のアプリでは、その瞬間に押していた行のタップが取り消されます。
`tap` は成功と出るのに行が選ばれず、次の検証で失敗します(遅い機械でだけ、たまに起きる形になります)。
増えた行だけを足す作り(`notifyItemRangeInserted`)のアプリでは起きません。回避策: 読み込み中の表示が
消えるのを待ってから押す。

```swift
scrollTo("#row_i_57", direction: .down, maxSwipes: 30)
waitForClose("#txt_loading", waitSeconds: 5)
tap("#row_i_57")
```

## ピンチで拡大

- `pinchOut(sel, scale: 2.0)` / `pinchIn(sel, scale: 0.5)` で拡大・縮小
- **実際に到達する倍率は部品の感度で変わります**(Android の `ScaleGestureDetector` は
  `scale: 2.0` の指示で実測 1.2 だった)。厳密な倍率ではなく「拡大したこと」を範囲で確かめる

```swift
pinchOut("#zoom_target", scale: 2.0)
select("#txt_zoom_scale").textMatches("^scale=(1\\.[1-9]|[2-4]\\.[0-9])$")
```

全フレームワーク共通(CMP `Modifier.transformable` / Flutter `InteractiveViewer` / RN
gesture-handler の `Gesture.Pinch()` / Android View `PinchZoomImageView`(`ScaleGestureDetector`
自前実装)/ SwiftUI `MagnificationGesture`)。拡大した中身は枠の外へはみ出さないよう
どのフレームワークもクリップしています。

## フレームワーク固有部品

各フレームワークにしか無い定番部品を1画面にまとめた節です。中身は SUT ごとに違うので、
対象アプリが同種の部品を使っているときだけ読んでください。共通の書き方は「`#id` かラベルで
指す・結果は echo で確かめる」で、他の節と変わりません。

| フレームワーク | 収録した部品 |
|---|---|
| CMP | M3 `HorizontalMultiBrowseCarousel` / `NavigationRail` / `BottomSheetScaffold` |
| Flutter | `Hero` での画面遷移(**トリガーのボタンではなく、別の視覚要素を `Hero` にする**のがこのアプリの実装。ボタン自体を `Hero` にすると遷移の見た目が不自然になるため)/ `CupertinoSwitch` / `CupertinoPicker` / `PlatformView`(ネイティブの `UILabel`/`TextView` をラベル付きで埋め込み) |
| RN | `@shopify/flash-list` の `FlashList`(**仮想化されるため、木に乗るのは画面に収まる分だけ** —— 他の `FlatList` 系画面と同じ特性)/ core の `Modal`(非全画面)/ core の `Switch` |
| Android View | `Spinner` / `NumberPicker` / `MotionLayout`(ボタン駆動の片道遷移) |
| SwiftUI(iOS) | `UICollectionView`(compositional layout)/ `.popover` / `.confirmationDialog`。**`.popover` は iPhone では adaptive presentation によりシート状に表示されることがある**(iOS 標準の既定挙動) |

### Link
- [index](../../index_ja.md)
