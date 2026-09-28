# FT E2EX iOS ネイティブアプリ UI 契約

**画面構成・`#id`・ラベル・echo 文字列は `E2EXAppCMP/docs/ui-contract.md`(唯一の正)と共通**。
このファイルは **iOS ネイティブ実装(SwiftUI + 一部 UIKit の慣用が無い箇所)固有の差分だけ**を書く。
tag 定数は `Sources/Tags.swift`(値は母体の表と byte 一致)。

- bundle id: `com.ftester.e2ex.ios`(Compose 版 `com.ftester.e2ex` と共存できる)
- 表示名: `FT E2EX iOS`
- ディープリンク: 持たない(URL Types 無し)
- 実装: 全画面 SwiftUI(この SUT は UIKit を要する部品が無い)
- 検証範囲: このタスクはビルド確認まで(シミュレータでの実地確認はスコープ外)。
  「未検証」と書いた項目は SwiftUI/UIKit の既知の挙動に基づく記載で、実機・シミュレータでの
  確認は今後の課題

## シェル

- `NavigationStack` + `navigationDestination(for: Route.self)`。ホームは `List` の
  `NavigationLink(value:)` 行(id は `nav_*`)
- `#txt_screen_title`: 各画面の `.toolbar { ToolbarItem(placement: .principal) { Text(...) } }`
- **`#btn_back` は存在しない**。システムの戻るボタン(スワイプバックも含めて標準のまま)は
  UINavigationBar が内部で描くボタンで `.accessibilityIdentifier` を設定する公開 API が無い。
  ラベルは前画面の `navigationTitle`(= 各画面の `#txt_screen_title` と同じ文字列)を使う
  (画面が狭いと OS が汎用の「戻る」に丸めることがある。この丸めの発生条件は未検証)

## 省いた画面(iOS に定番の慣用が無い)

- **ドロワー**: `nav_drawer` ごと省く。iOS にモーダルなナビゲーションドロワーの標準部品は無い
- **ツールチップ**: `nav_tooltip` ごと省く。iOS の長押しはコンテキストメニュー(`UIMenu`)に
  倒れる慣用で、母体の「常駐する吹き出し」とは別物

## 各画面の部品と差分

| 画面 | 部品 | 差分・注記 |
|---|---|---|
| ページャ | `TabView(.page)` | 同一 |
| ボトムシート | `.sheet` + `.presentationDetents([.medium, .large])` | 同一。dismiss 判定は `onDismiss` で「選択せずに閉じたか」を自前管理 |
| メニュー | `Menu` / `Picker(.pickerStyle: .menu)` | **未検証**: `Menu`/`Picker(.menu)` は `UIMenu` 経由でポップアップを描くため、項目に付けた `.accessibilityIdentifier`(`menu_item_*` / `opt_fruit_*`)が AX ツリーへ届くかは SwiftUI の公開 API では保証されない。届かない場合はラベル文字列(`コピー`/`共有`/`削除`/`りんご`/`バナナ`/`さくらんぼ`)で引く。`field_fruit` は Picker 本体に付けてあり届く想定 |
| 日付ピッカー | `.sheet` + `DatePicker(.graphical)` | 初期値 2026-01-15 は UTC カレンダーで固定(表示・読み出しとも `.environment(\.timeZone, UTC)`)。iOS の `DatePicker` は必ず値を持つため **`date=null` は発生しない**(母体は Compose の「未選択で OK」を想定するが iOS 側の契約から外れる) |
| ドロワー | (省略) | 上記参照 |
| 引っ張って更新 | `List` + `.refreshable` | 同一。Compose 側にある `#box_refresh` 相当のコンテナ id は無い(List 自体が容器) |
| スナックバー | **カスタム toast**(共通部品。`ZStack` オーバーレイ) | iOS に定番のスナックバーは無いため自前実装。長い方 10 秒 + 「元に戻す」/ 短い方 4 秒。内部ボタンに id は付けない(母体契約どおりラベルで引く) |
| グリッド | `ScrollView` + `LazyVGrid`(3 列) | 同一 |
| スワイプで削除 | `List` + `.swipeActions(edge: .trailing, allowsFullSwipe: true)` | 右→左のフルスワイプで削除。leading 側は未登録 = 左→右は無効(登録しないことで表現) |
| タブ | `Picker(.segmented)` / 横 `ScrollView` のボタン列 / 埋め込み `TabView`(タブバー) | 固定タブ(`tab_a/b/c`)は Segmented Picker(id は各セグメントの `Text` に直接付与、実機で機能する慣用)。スクロールタブは横 `ScrollView` のボタン列。**下部ナビゲーションバーは未検証**: `TabView` の `tabItem` に付けた identifier(`navbar_*`)が実際の `UITabBarButton` まで届くかは iOS バージョン依存で知られた不安定挙動があり、届かない場合はラベル(`ホーム`/`探す`/`設定`)で引く |
| アニメーション | `withAnimation` + `.transition(.opacity)` / `.contentTransition(.numericText())` | 同一。`visible=` の表示はボタン押下と同時に切り替え、見た目の遷移だけ 1.5 秒かける |
| ツールチップ | (省略) | 上記参照 |
| チップと分割ボタン | `Toggle(.toggleStyle(.button))` / `Button(.bordered)` / `Picker(.segmented)` | **`RangeSlider` は省略**(SwiftUI に範囲スライダーの標準部品が無い)。`#txt_range_result` は固定値 `range=20-80` を表示するだけで、対応する操作可能な部品は無い |
| 検索バー | `.searchable` + `.searchSuggestions` + `.onSubmit(of: .search)` | 候補行は `Button`(タップで即確定)。**`#field_search` は存在しない**: `.searchable` が出す検索欄(System 提供の `UISearchBar` 相当)に `.accessibilityIdentifier` を渡す公開 API が無いため、プレースホルダ文字列 `検索` で引く |
| 引数付き遷移 | `List` の `NavigationLink(value:)` | 同一。詳細画面の「次の詳細」も `NavigationLink(value:)` で path に自動追加される(手動の path 操作は無し) |

## 第2弾の実装(iOS)

画面構成・`#id`・ラベル・echo は `E2EXAppCMP/docs/ui-contract-wave2.md` と共通。以下は各画面の部品と、
そこからの差分だけ。

| 画面 | 部品 | 差分・注記 |
|---|---|---|
| 伸縮するヘッダ | `List` + `.navigationBarTitleDisplayMode(.large)` | **`#txt_screen_title` 相当の id は付かない**: 実際に伸縮するのはシステムの大見出しで、`#btn_back` と同じ理由(UINavigationBar が内部描画・公開 API 無し)で accessibilityIdentifier を持てない。契約の `#txt_collapse_header`(`大きな見出し`)はリスト先頭に置く別要素で代替し、こちらは通常のスクロールで流れる(大見出し自体の代役ではなく、契約が求める id 付きテキストの置き場)。`#txt_collapse_result` は `.safeAreaInset(edge: .top)` に置いて縮小後も木に残す |
| 貼り付く見出し | `List(.plain)` + `Section(header:)` | 同一。plain スタイルの Section 見出しは標準で上端に貼り付く |
| 時刻ピッカー | `.sheet` + `DatePicker(.wheel, .hourAndMinute)` | 同一。24 時間表記は `.environment(\.locale, Locale(identifier: "ja_JP"))` で得る(初期 09:30) |
| ダイアログ | `.alert` / `.alert` + `TextField` / `.confirmationDialog` / `.fullScreenCover` | **`#btn_toast` は省略**(iOS に OS 標準のトーストが無い。スナックバー画面の自前 toast とは別物で、ここでは作らない)。alert 内 `TextField`(`field_prompt`)は UIAlertController が描くため id 到達は **未検証**(Menu 項目と同じ制約) |
| 長押しメニュー | `.contextMenu` | 同一。メニュー項目(編集/複製/削除)自体には id を付けない(結果は state 経由で読める) |
| 並べ替え | `List` + `.onMove` + `.environment(\.editMode, .constant(.active))` | 常時編集モードでハンドルを常に表示し、右端のハンドルを掴んでドラッグする形(`EditButton` は使わない) |
| 入力の種類 | `TextField`(`.numberPad` / `.vertical` axis)/ `SecureField` / `@FocusState` / 候補 `Button` 列 | **`#txt_focus_echo` の初期値は契約が明記しないため `focus=none` を補完**(他画面の "none" 初期値規約に合わせた選択。デビエーションではなく補完) |
| FAB | overlay `Button`(bottom-trailing)+ `.toolbar(placement: .bottomBar)` | iOS に FAB の定番が無いため自作(契約どおり)。**行ラベル `行 F00`…`行 F29` は契約が明記しないため他画面の命名(`行 <suffix>`)に揃えて補完** |
| 展開するリスト | `DisclosureGroup`(List 内) | 同一。`isExpanded` を束縛しないため既定で閉じる |
| ステッパーと進捗 | `Stepper` / `ProgressView(value:)` / `ProgressView()` | **`btn_qty_plus`/`btn_qty_minus` は存在しない**: +/- は `Stepper` 本体(`stepper_qty`)に一体化しており、システム標準ラベルで表面化する(契約どおり) |
| 無限スクロール | `List` + 末尾行の `.onAppear` | 同一。0.8 秒後に 20 行追加(最大 100) |
| ピンチで拡大 | `MagnificationGesture` + `scaleEffect` | **`MagnifyGesture` ではなく `MagnificationGesture` を使用**(前者は iOS 17+ 限定 API で、本 SUT の deployment target iOS 16.0 に合わない。挙動は同一)。パンは `DragGesture` を `simultaneousGesture` で追加 |
| 固有部品 | `UICollectionViewCompositionalLayout`(`UIViewControllerRepresentable`)/ `.popover` / `.sheet` + `.presentationDetents([.fraction(0.25)])` | **`btn_detent`・`btn_detent_tapped` は契約が id を明記しないため独自に追加**(全タップ可能要素に id を付ける方針への補完。echo `native=detent:tapped` は契約どおり)。`.popover` は iPhone では adaptive presentation によりシート状に表示されうる(iOS 標準の既定挙動。見た目の差はテスト対象外) |

## ビルド

```sh
cd E2EXAppIOS
./scripts/build-ios.sh    # → dist/ios-simulator/FTE2EXIOS.app
```

`xcodegen` が必要(`brew install xcodegen`)。
