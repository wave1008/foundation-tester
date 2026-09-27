# UI 部品ごとの書き方と癖(Compose Multiplatform)

Compose Multiplatform(Material3)の定番部品を、シナリオでどう指し・どう操作し・どう確かめるかの
まとめです。**エージェント(AI アシスタント)がシナリオを書くときの知識として使う**ことを想定して
います —— 対象アプリの画面に同じ部品があれば、該当する節を読んでから書いてください。

- 確かめた環境: Compose Multiplatform 1.11(Material3 1.4 相当)・iOS 27 Simulator(hybrid エンジン /
  XCUITest エンジン)・Android 15 Emulator。確かめたのは 2026-09-28
- 各節の挙動は fleetest 同梱の検証アプリ `E2EXAppCMP/` と、そのシナリオ
  `TestProjects/E2EX-CMP/scenarios/` で再現できます(同じ部品の書き方の実例として読めます)
- **「現時点の制約」は fleetest 側で未解決の制約**です。書いてある回避策で書いてください

## 全部品に共通すること

### モーダルが開いている間、背後の画面は木から消える

ドロワー・ドロップダウンメニュー・ボトムシートが開いている間、**背後の画面の要素は木
(スナップショット)に載りません**(ドロワーとメニューは iOS / Android の両方、ボトムシートは iOS で確認)。
残るのはモーダルの中身と、スクリム(背景の暗幕)の「閉じる」ボタンだけです。

- 背後の結果表示(`#txt_result` 等)は、**モーダルを閉じてから**読む
- 「メニューの外側を押して閉じる」は背後の要素を指せないので、要素のタップでは書けない
  (書き方は下の「ドロップダウンメニュー」の節)

```swift
tap("#btn_open_drawer")
exist("#txt_drawer_header")          // ○ 開いた証拠はモーダルの中で取る
// select("#txt_state").textIs(...)  // × 背後の要素は開いている間は見つからない
tap("#drawer_item_sent")             // 閉じてから
select("#txt_state").textIs("drawerOpen=false")
```

### アイコンだけのボタンは contentDescription がラベル

`IconButton { Icon(…, contentDescription = "戻る") }` は、ラベル `戻る` で指せます(`tap("戻る")`)。
アイコンの代わりに文字(`Text("←")`)を置いている画面では、iOS のラベルが `戻る, ←` のように
**文字と連結されます**。その場合は `#id` で指すか、部分一致 `*戻る*` で書いてください。

### 横に送る容器は scrollFrame を必ず渡す

`scroll: .right` / `withScrollRight { }` は、指定が無いと**画面の中央**を払います。ページャや横に
はみ出すタブ列が画面の中央に無いと、何も動かずに失敗します。**横の容器を探索するときは、その容器を
`scrollFrame:` で指定**してください(容器に `#id` が必要です)。

```swift
withScrollRight(scrollFrame: "#pager_main") {
    tap("#btn_page_4")
}
```

### Android の画面端は OS の「戻る」

ジェスチャーナビゲーションの Android では、**画面の左右の端から始めた横の払いは OS の「戻る」**に
なります。払いの始点を画面の端に寄せないでください(`flickLeftToRight(startMarginRatio:)` を小さく
しない。既定のままにする)。

## ページャ(HorizontalPager)

- 次のページへ: `flickRightToLeft(scrollFrame: "#pager_main")`(1回で1ページ)
- 画面外のページの要素へ: `withScrollRight(scrollFrame: "#pager_main") { tap("#…") }`
- 端まで戻す: `scrollToLeftEdge(scrollFrame: "#pager_main")`(`scrollToRightEdge` も同じ)
- 今のページは、アプリが出しているページ番号の表示で確かめる

## ボトムシート(ModalBottomSheet)

- 開いた証拠はシートの中の要素で取る(背後は木から消える)
- シートの中の長いリスト: `tap("#row_25", scroll: .down)` で届く(シートが伸びてから中が送られる)
- 選択肢を押して閉じる形は両 OS とも問題なし
- 払って閉じる: **見出しからシートの下のほうの行まで指を動かす**(両 OS)。`swipeBy` は使わない ——
  比率は**対象の大きさに対する割合**で片側 0.9 が上限なので、小さい見出しでは数 pt しか動かない
- iOS はスクリムの「閉じる」ボタンでも閉じられる —— iOS の木にはラベル `シートを閉じる` のボタンが出る
  (日本語ロケール。ラベルはロケールで変わる)

```swift
swipeElementToElement("#sheet_title", "#row_04", durationSeconds: 0.3)
ios { tap("シートを閉じる") }   // こちらでもよい
```

## ドロップダウンメニュー(DropdownMenu)

- 項目は `#id` でもラベルでも押せる(`tap("#menu_item_share")` / `tap("削除")`)
- 項目を押すとメニューは閉じる
- **外側を押して閉じる**: 背後が木に無いので要素では指せません。
  Android は `back()`、iOS は画面の空いた場所を座標で押す

```swift
tap("#btn_open_menu")
android { back() }
ios { tap(x: 200, y: 600) }   // メニューに重ならない空いた場所
notExist("#menu_item_copy")   // 閉じたことを確かめる
```

## 選択式の入力欄(ExposedDropdownMenuBox)

- 欄を押すと候補が出る(`tap("#field_fruit")` → `tap("#opt_banana")`)
- **選んだ値は `.text` ではなく `.value` に出ます**。`.text` は iOS では欄のラベル(例: `果物`)、
  Android では `nil` です

```swift
select("#field_fruit").valueContains("バナナ")   // ○ 両 OS
// select("#field_fruit").textContains("バナナ") // × iOS はラベル・Android は nil
```

## 日付ピッカー(DatePickerDialog)

- 日付のセルには `#id` を付けられません。**ラベルで指します**。ラベルはロケールで変わるので、
  候補を `||` で並べます

```swift
tap("*1月20日*||*January 20*||20")
tap("#btn_date_ok")
```

- OK / キャンセルのボタンはアプリ側で `testTag` を付けられるので `#id` で指す

## ナビゲーションドロワー(ModalNavigationDrawer)

- ボタンで開く・項目を押して閉じる形は両 OS とも問題なし
- 開いている間、背後の画面は木から消える(「全部品に共通すること」の節)。
  状態の表示は閉じてから読む
- **払って開く**: `flickLeftToRight()` / 閉じるのは `flickRightToLeft()`(両 OS)。**始点は既定のまま**に
  する —— Android で `startMarginRatio:` を小さく(0.05 など)すると、始点が画面の端に入って OS の
  「戻る」になり、前の画面へ戻ってしまう

## 引っ張って更新(PullToRefreshBox)

- 更新させる: 一覧の上の行から下の行へ指を動かす
  (`swipeElementToElement("#row_01", "#row_06", durationSeconds: 0.6)`)
- 更新の完了はアプリの表示(回数・時刻など)で確かめる

**現時点の制約**: **iOS の XCUITest エンジン**(`iosInappEngine: false`)では、一覧の上端で
`scrollToTop()` を使うと**更新が1回余分に走ります**(端に着いたことを確かめる送りが「引っ張る」に
なる。XCUITest は容器が「まだ送れるか」を教えないため)。Android と iOS の既定エンジンでは起きません。
回避策: 更新の回数を検証するシナリオでは、`scrollToTop()` の後に回数を読まない(回数の検証は
`scrollToTop()` より前に済ませる)。

## スナックバー(Snackbar)

- 中身には `#id` を付けられません。メッセージもアクションも**ラベルで指します**
  (`exist("削除しました")` / `tap("元に戻す")`)
- 自然に消えるのを待つ: `waitForClose("保存しました", waitSeconds: 10)`
  (短い表示は約4秒・長い表示は約10秒)

## グリッド(LazyVerticalGrid)

- 画面外のセルは木に居ません。`tap("#cell_86", scroll: .down)` で届く。戻りは `scroll: .up`
- 1行に複数の要素が並んでも、縦の探索はそのまま使える

## スワイプで削除(SwipeToDismissBox)

- 行の上で横に払う: `swipeBy("#row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)`(両 OS で確認)。
  比率の上限は片側 0.9。Android では、指が OS の「戻る」の帯(画面の左右の端)に入らないように
  ツールが経路を内側へ寄せる
- 無効な向きへ払っても何も起きないこと(行が残ること)も確かめられる

## タブ(PrimaryTabRow・ScrollableTabRow・NavigationBar)

- 固定のタブは `#id` でもラベルでも押せる(`tap("#tab_b")` / `tap("タブC")`)
- 横にはみ出すタブ列は、**タブ列に `#id` を付けて `scrollFrame:` に渡す**
  (`withScrollRight(scrollFrame: "#stab_row") { tap("#stab_11") }`)
- NavigationBar の項目はラベル(アイコンの下の文字)で押せる

## アニメーション(AnimatedVisibility・AnimatedContent)

- フェードで出る要素も `select("#…").textIs("…")` でそのまま読める(読めるようになるまで待たれる)
- 消えるのを待つ: `waitForClose("#…", waitSeconds: 5)`
- 切り替えアニメーション中に続けて押しても、最後の値が読める

## ツールチップ(TooltipBox)

- アンカーを長押しする: `tap("#btn_info", holdSeconds: 1.0)`。iOS ではこれで出ます

- **Android では検証できません**。Material3 のツールチップは**押している間だけ**表示され、指を離すと
  消えます(`tap(holdSeconds:)` は離してから次へ進むので、次の行では消えている)。表示中も、
  ツールチップの文字は別ウィンドウなので木に載りません。ツールチップの確認は `ios { }` で囲む

## チップと分割ボタン(FilterChip・SegmentedButton)

- FilterChip の選択状態は `checkIsON()` / `checkIsOFF()` で読める(両 OS)
- SegmentedButton の選択状態も `checkIsON()` / `checkIsOFF()` で読める
- RangeSlider のつまみには `#id` を付けられません。値はアプリが出している表示で確かめる

## 検索バー(SearchBar)

- 入力欄を押して `type("…")`、候補を `#id` で押す(両 OS・両エンジン)
- iOS の SearchBar の入力欄は、入力した文字の代わりに説明文(日本語ロケールで「検索候補は次のとおりです」)を
  **値として出します**。`select("#field_search").valueIs(…)` では入力を確かめられないので、候補の表示や
  確定後の結果で確かめる(ツールは画面の OCR で入力を確かめるので、`type` 自体は重複せずに通る)

## 画面遷移(navigation-compose の NavHost)

- 引数付きの遷移・積み重ね・アイコンだけの戻るボタンは両 OS とも問題なし
- `back()` は Android では OS の戻る、iOS ではエッジスワイプで1画面戻る

### Link
- [index](../index_ja.md)
