# FT E2E iOS ネイティブアプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EAppCMP/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを両 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **iOS ネイティブ実装(SwiftUI + UIKit)固有の差分だけ**を定義する。
tag 定数は `Sources/Tags.swift` に集約する(値は共通契約の表と byte 一致)。

- bundle id: `com.ftester.e2e.ios`(Compose 版 `com.ftester.e2e` と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.ios`
- シナリオ: `TestProjects/E2E-iOS/scenarios/`

## 画面回転(この SUT 固有の罠)

**横向きにすると `#txt_screen_title` が画面外へ出る画面がある**(2026-08-11 実測。テキスト入力画面で
確認)。SwiftUI のレイアウトが縦に詰めるため、タイトルが可視領域の上へ追い出される。
**回転を含むシナリオで着地判定にタイトルを使わない** —— その画面の本体の要素
(例: `#field_single`)を見ること。共通契約は E2EAppCMP/docs/ui-contract.md §画面回転。

## 実装方式(どの画面が SwiftUI で、どこが UIKit か)

型語彙のカバレッジを稼ぐため、次の2画面だけ UIKit を混ぜる。他は SwiftUI。

| 画面 | 実装 | ツリー上の型 |
|---|---|---|
| テキスト入力 | `UITextField` / `UITextView`(UIViewRepresentable) | `textField` / `secureTextField` / `textView` |
| スクロール | `UITableView`(UIViewRepresentable) | `table` + 行ごとに `clickable` |
| それ以外 | SwiftUI | `button` / `staticText` / `switch` / `slider` / `other` |

## Compose 版との差分(実スナップショットで採取。2026-07-23・iPhone 17 Pro/iOS 27.0)

| 項目 | Compose 版 | iOS ネイティブ版 |
|---|---|---|
| ボタンの型 | `button`(2026-07-26 の正規化で Android も一致) | `button` |
| テキストの型 | `staticText` | `staticText` |
| 入力欄の型 | `textField` のみ | `textField` / `secureTextField` / `textView` に分かれる |
| リスト行 | `button`(LazyColumn) | `clickable`(UITableView)+ 親に `table` |
| チェックボックス | `checkBox` | `button`(iOS ネイティブに Checkbox は無い) |
| ラジオ | `checkBox` | `button`(同上) |
| ダイアログ見出し | `#txt_dialog_title` で引ける | **id が付かない**。ラベル `確認` で引く(下記) |
| id の露出 | Android はルートで `exposeTestTagsAsResourceId()` 必須 | `.accessibilityIdentifier` がそのまま `#id` |

### セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は Compose 版と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.button[6]`。レイアウトを変えたら採取し直す。

### ダイアログ(`.alert` = UIAlertController)

- **ボタンには `.accessibilityIdentifier` が届く**(別ウィンドウでも `#btn_dialog_ok` / `#btn_dialog_cancel` が引ける)
- **title / message には届かない**。UIAlertController が自前で描く StaticText で、
  `.accessibilityIdentifier` を付けても捨てられる(message 側に置いても同じ。実測で確認済み)
  → **`#txt_dialog_title` は存在しない**。見出しの検証はラベル `確認` で行う
- ボタンは同一 id のノードが**2つ**出る(SwiftUI の内部構造)。`#id` 指定は先頭に解決されるため実害なし。
  ただし `.button[n]` の序数はダイアログ表示中ずれる

### UITableView の a11y 上の癖(採取済み)

- 既定ではセルのテキストが**独立した StaticText** として出て `clickable` 側が無ラベルになる。
  ラベルセレクタ(`.clickable=行 03`)を引けるよう、`textLabel?.isAccessibilityElement = false` +
  `cell.accessibilityLabel` へ集約している(`Sources/UIKitViews/RowTableView.swift`)
- **可視範囲＋数行しかセルを実体化しない**。画面外の行は `#id` ごとツリーに存在しない
  (= `scrollTo` なしの `exist` が落ちる契約の検証材料。Compose の LazyColumn と同じ挙動)
- ただし**行ラベルの StaticText は全 40 行ぶんツリーに残る**(id 無し・frame は先頭行相当に
  クランプ。2026-07-27 実測)。**ラベルの部分一致で不在検証はできない**
  (`notExist("*行 3*")` は画面外の `行 30`〜`行 39` に正当に当たる。シナリオ 14 は
  `textContainsNot("#row_03", …)` で同じ契約を検証している)
- **画面外要素の frame は下端バンドにクランプされて報告される**(design.md §4.6 の既知制約)。
  Compose 固有ではなく **UIKit のスクロールコンテナでも起きる**。行高を 56pt 以上にして回避している

### SF Symbol のラベル汚染

`Image(systemName:)` は既定で記号名(`Square` / `Circle`)が a11y ラベルになり、
`#radio_b` と `#radio_c` が同じ `Circle` ラベルで衝突する。
チェック/ラジオの Image は `.accessibilityHidden(true)` で隠してある。

### `#field_single` の IME アクション(`pressEnter`)

`#field_single` は UIKit の `UITextField`。`insertText("\n")` では改行が文字として入るだけで
return が発火しないため、in-app ブリッジは **UIKit が Return で行うこと自体を再現する**
(`delegate` の `textFieldShouldReturn:` + `EditingDidEndOnExit`。
`InAppBridge/Sources/InAppInput.m` の `FTPressEnterOnComposeFirstResponder`)。
この SUT の `Coordinator` は `textFieldShouldReturn:` で `onSubmit` を呼ぶので `#txt_ime_action` が進む。

**xcuitest フォールバックには頼れない**(2026-07-28 実測): hybrid で 409 を返すと
`typeText("\n")` へ回るが、フォーカスを立てたのは in-app の合成タッチなので **XCUITest からは
keyboard focus を持つ要素として見えず無言 no-op になる**。だから in-app 側で完結させている。

### Toggle / Slider

- `Toggle` は AX ツリー上は同一 frame の `switch` ノードが2つある(id 付き1つ + id 無し1つ・幅が 2pt 違う)。
  **ブリッジが後から来て何も足さない方を落とすので、スナップショットには1つしか出ない**
  (2026-08-06 / protocol 53。規則は `Sources/FTCore/SnapshotDedupe.swift`)。
  同じ畳み込みは `UIAlertController` のボタン(`#btn_dialog_ok` / `#btn_dialog_cancel`)にも効く
- `Slider` の value は `"50%"`(パーセント表記)。**アプリの状態**の値検証は echo Text(`#txt_slider`)で行う契約。例外が1箇所: 10_ライフサイクルとコントロール の `valueIs("50%")` は**ブリッジが value を供給していること**の検証で、echo では代替できない(SUT が自前で描くのでブリッジが黙っても緑のまま)

### WebView 画面(SUT 固有の実測)

- コンテナ(`WKWebView`)は xcuitest / in-app とも `webView` 型 + `#wv_container`。
  **in-app は a11y ツリーでは中身を見られない**(Web コンテンツの a11y は WebContent プロセスが
  提供する)ため、**DOM を JS で読む**(`InAppWebViewDOM`)。この SUT は uikit ホストなので
  DOM 経路が有効 = WebView 画面でも in-app の速度が出る。
- 中身が a11y に現れるまで **約 2.3 秒**(内蔵 HTML・2026-07-29 実測)。
- HTML の `id` は **identifier に来ない**。`aria-label` は label に来る。
- 空の `<input>` は WebKit が **placeholder を AXValue に入れて返す**(UIKit の入力欄は入れない)。
  ブリッジが `value == placeholderValue` を空へ正規化するので、
  スナップショットは `ph="WebView 入力" empty` になる(2026-08-06 / protocol 53)。
  これが無いと `valueIs("")` が iOS の WebView でだけ通らない。

## ホームの `#nav_heal` / `#nav_diagnostics` は**意図して下部タブに重ねてある**

11 行が 1 画面に収まらず、`#nav_heal` (16,788 370x62) が下部タブ `#tab_controls` の下に着地し、
`#nav_diagnostics` は画面外に出る。**直さないこと** —— MCP の
「上に描かれた要素に覆われている」警告(`RefGuard.overlayCovering`)の唯一の生きた witness で、
E2E-CMP の飛び越し画面と同じ役割を持つ。この2つを叩くシナリオは `_disabled/` にしか無いので
通常実行には影響しない(母体の契約 `E2EAppCMP/docs/ui-contract.md` §ホームタブ にも記載)。

## ビルド

```sh
cd E2EAppIOS
./scripts/build-ios.sh    # → dist/ios-simulator/FTE2EIOS.app
```

`xcodegen` が必要(`brew install xcodegen`)。

## 覆い画面(`#nav_cover`)の型と罠

**内容をシェルのタブバーの下へ潜らせている**(`.padding(.bottom, -72)`)。tag と値の契約は
母体(`E2EAppCMP/docs/ui-contract.md`)側にある。iOS 固有の罠が2つ:

- **自前のフッタを ZStack で重ねても witness にならない**。iOS の a11y の木では重ねた側が
  容器より**先**に出るため、描画順を木の順序で代理する遮蔽判定(`FTCore.PaintOrder`)が
  成立しない(2026-08-27 に実測)。シェルのタブバーを使うこと。
- そのタブバーも、既定では**内容より先**に並ぶ。覆い画面は内容側に
  `.accessibilitySortPriority(1)` を付けて「内容 → タブバー」の順にしている。
  **この指定を外すと、潜っていることをツールが判定できなくなる**(緑のまま素通りする)。

