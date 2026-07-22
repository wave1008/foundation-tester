# FT E2E iOS ネイティブアプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EApp/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを両 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **iOS ネイティブ実装(SwiftUI + UIKit)固有の差分だけ**を定義する。
tag 定数は `Sources/Tags.swift` に集約する(値は共通契約の表と byte 一致)。

- bundle id: `com.ftester.e2e.ios`(Compose 版 `com.ftester.e2e` と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.ios`
- シナリオ: `Projects/E2E-iOS/Scenarios/`

## 実装方式(どの画面が SwiftUI で、どこが UIKit か)

型語彙のカバレッジを稼ぐため、次の2画面だけ UIKit を混ぜる。他は SwiftUI。

| 画面 | 実装 | ツリー上の型 |
|---|---|---|
| テキスト入力 | `UITextField` / `UITextView`(UIViewRepresentable) | `TextField` / `SecureTextField` / `TextView` |
| スクロール | `UITableView`(UIViewRepresentable) | `Table` + 行ごとに `Cell` |
| それ以外 | SwiftUI | `Button` / `StaticText` / `Switch` / `Slider` / `Other` |

## Compose 版との差分(実スナップショットで採取。2026-07-23・iPhone 17 Pro/iOS 27.0)

| 項目 | Compose 版 | iOS ネイティブ版 |
|---|---|---|
| ボタンの型 | iOS `Button` / Android `Cell` | `Button`(OS 差なし = `ios{}`/`android{}` 分岐が不要) |
| テキストの型 | `StaticText` | `StaticText` |
| 入力欄の型 | `TextField` のみ | `TextField` / `SecureTextField` / `TextView` に分かれる |
| リスト行 | `Button`(LazyColumn) | `Cell`(UITableView)+ 親に `Table` |
| チェックボックス | `Checkbox` | `Button`(iOS ネイティブに Checkbox は無い) |
| ラジオ | `RadioButton` | `Button`(同上) |
| ダイアログ見出し | `#txt_dialog_title` で引ける | **id が付かない**。ラベル `確認` で引く(下記) |
| id の露出 | Android はルートで `exposeTestTagsAsResourceId()` 必須 | `.accessibilityIdentifier` がそのまま `#id` |

### セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は Compose 版と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.Button[6]`。レイアウトを変えたら採取し直す。

### ダイアログ(`.alert` = UIAlertController)

- **ボタンには `.accessibilityIdentifier` が届く**(別ウィンドウでも `#btn_dialog_ok` / `#btn_dialog_cancel` が引ける)
- **title / message には届かない**。UIAlertController が自前で描く StaticText で、
  `.accessibilityIdentifier` を付けても捨てられる(message 側に置いても同じ。実測で確認済み)
  → **`#txt_dialog_title` は存在しない**。見出しの検証はラベル `確認` で行う
- ボタンは同一 id のノードが**2つ**出る(SwiftUI の内部構造)。`#id` 指定は先頭に解決されるため実害なし。
  ただし `.Button[n]` の序数はダイアログ表示中ずれる

### UITableView の a11y 上の癖(採取済み)

- 既定ではセルのテキストが**独立した StaticText** として出て `Cell` 側が無ラベルになる。
  ラベルセレクタ(`.Cell=行 03`)を引けるよう、`textLabel?.isAccessibilityElement = false` +
  `cell.accessibilityLabel` へ集約している(`Sources/UIKitViews/RowTableView.swift`)
- **可視範囲＋数行しかセルを実体化しない**。画面外の行は `#id` ごとツリーに存在しない
  (= `scrollTo` なしの `exist` が落ちる契約の検証材料。Compose の LazyColumn と同じ挙動)
- **画面外要素の frame は下端バンドにクランプされて報告される**(design.md §4.6 の既知制約)。
  Compose 固有ではなく **UIKit のスクロールコンテナでも起きる**。行高を 56pt 以上にして回避している

### SF Symbol のラベル汚染

`Image(systemName:)` は既定で記号名(`Square` / `Circle`)が a11y ラベルになり、
`#radio_b` と `#radio_c` が同じ `Circle` ラベルで衝突する。
チェック/ラジオの Image は `.accessibilityHidden(true)` で隠してある。

### Toggle / Slider

- `Toggle` は同一 frame の `Switch` ノードが2つ出る(id 付き1つ + id 無し1つ)。`#id` 指定なら実害なし
- `Slider` の value は `"50%"`(パーセント表記)。値検証は echo Text(`#txt_slider`)で行う契約

## ビルド

```sh
cd E2EAppIOS
./scripts/build-ios.sh    # → dist/ios-simulator/FTE2EIOS.app
```

`xcodegen` が必要(`brew install xcodegen`)。
