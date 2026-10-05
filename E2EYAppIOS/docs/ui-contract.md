# FT E2EY iOS ネイティブアプリ UI 契約

**画面構成・`#id`・ラベル・echo 文字列は `E2EYAppCMP/docs/ui-contract.md`(唯一の正)と共通**。
このファイルは **iOS ネイティブ実装(SwiftUI + 一部 UIKit)固有の差分だけ**を書く。
tag 定数は `Sources/Tags.swift`(ホームの `nav_*`・`#txt_screen_title`・`#btn_back`)。画面内の `#id` は各 `Sources/Screens/*.swift` に直書き。

- bundle id: `com.ftester.e2ey.ios`
- 表示名: `FT E2EY iOS`・ディープリンクは持たない
- 最小 iOS 17.0(`scrollPosition(id:)` / `scrollTargetBehavior` / `onChange` の2引数形を使う)・Swift 言語モードは E2EX 版を踏襲して 5
- 検証範囲: ビルドまで。デバイスでの実地確認は未実施(「未確認」と書いた項目)

## シェル

- `NavigationStack` + `navigationDestination(for: Route.self)`。ホームは `List` の `NavigationLink(value:)` 行(`nav_*`)
- `#txt_screen_title`: `.toolbar { ToolbarItem(placement: .principal) { Text(...) } }`
- **`#btn_back` は A8 の編集画面にだけある**。他の画面のシステムの戻る(エッジスワイプ含む)は UINavigationBar が内部で描くので
  `#BackButton`(ラベルは前画面の `navigationTitle`)で指す

## 画面 → 使った部品

| 画面 | 部品 |
|---|---|
| A1 入れ子スクロール | `List` の各行に `ScrollView(.horizontal)` + `LazyHStack` |
| A2 反転チャット | UIKit `UITableView`(`transform = scaleY(-1)`・セルの `contentView` も反転し直す)を `UIViewControllerRepresentable` で載せる。**入力バー(`#field_chat` + `#btn_send`)は VC の `inputAccessoryView`**(`canBecomeFirstResponder = true`)。echo と `#btn_incoming` は SwiftUI の固定領域、`#btn_jump_bottom` は VC の中の `UIButton` |
| A3 読み込みの状態 | `List` + `.redacted(reason: .placeholder)` の骨組み行(`.disabled(true)`)+ 末尾の番兵行の `.onAppear` |
| A4 スワイプの操作 | `.swipeActions(edge: .trailing, allowsFullSwipe: true)`(**削除を先頭に並べる** = full swipe が削除に当たる)+ `.swipeActions(edge: .leading)`(ピン留め)。返信行は `DragGesture` の自前 |
| A5 選択モード | `List(selection:)` + `EditMode`(`#btn_edit` は自前の `Button` で `editMode` を切り替える)。通常モードの押す・長押しは editMode が非活性の枝だけに付ける |
| A6 文中リンク | `Text(AttributedString)` の `.link`(`e2ey://…`)+ `OpenURLAction` で echo。行の本体は `onTapGesture` |
| A7 PIN と OTP | OTP: `TextField`(`.numberPad`・`opacity(0.011)`)の上に6つの箱を重ね、箱の `onTapGesture` で `@FocusState` を立てる。PIN: `LazyVGrid` の自前キーパッド |
| A8 戻るの横取り | `navigationBarBackButtonHidden(true)` + 自前の `#btn_back`(`ToolbarItem`)+ `interactivePopGestureRecognizer` の delegate 差し替え(`EdgeSwipeGuard`)+ 自前のダイアログ(`ZStack`)|
| A9 引き伸ばせるシート | `.sheet` + `.presentationDetents([.height(64), .medium, 全開], selection:)` + `.presentationBackgroundInteraction(.enabled)` + `.presentationContentInteraction(.resizes)` + `.interactiveDismissDisabled()` |
| A10 スクロールで隠れるバー | SwiftUI: `ScrollView` のスクロール量(`GeometryReader` + `PreferenceKey`)を読んで自前のバーを平行移動。**UIKit の `hidesBarsOnSwipe` は選ばない**(隠れるのが `UINavigationBar` になり、`#bar_top_hiding` 等の `#id` を付けられず、`#txt_screen_title` / 戻るまで一緒に消える) |
| A11 折りたたみヘッダとタブ | 縦 `ScrollView` 1つ + `LazyVStack(pinnedViews: [.sectionHeaders])`(タブ列が貼り付く)+ 横の paging `ScrollView`(`scrollTargetBehavior(.paging)` + `scrollPosition(id:)`) |
| A12 高さの揃わないグリッド | 列ごとの `LazyVStack` を2本並べ、短い列へ詰める(同じなら左) |

## 契約からの逸脱

- **A8 のダイアログは `.alert` ではなく自前の `ZStack` オーバーレイ**: `.alert` の中身(`UIAlertController`)には `#id` を付けられず、
  `#txt_discard_title` / `#btn_discard` / `#btn_keep` を契約どおり持てないため
- **A8 のエッジスワイプ**: システムの戻るを隠すと UIKit はエッジスワイプも無効にする。**判定(パネルを閉じる → 空なら戻る → 文字があればダイアログ)を
  `#btn_back` とエッジスワイプの両方に通すため、delegate を差し替えて `gestureRecognizerShouldBegin` で判定を呼ぶ**
  (戻らない判定のときは false を返す)。つまり契約の「理想」(2・3 とも同じ結果)を満たす。未確認: iOS 26 の
  `interactiveContentPopGestureRecognizer`(コンテンツ上の右払い)は画面にいる間だけ切ってある
- **A9 の全開は `.large` ではなくカスタム detent**(最大高 − 150pt): `.large` だと上部の固定領域(echo)をシートが覆うため。
  半分は `.medium`、畳んだ状態は `.height(64)`。**畳むとシートの中身が入れ替わる**(ミニプレーヤー ⇄ 見出し + キュー)ので、
  畳んだ状態ではキューは木に居ない。未確認: シートのスワイプが `.resizes` どおり「まずシート → 伸び切ってから中身」になるか
- **A11 は縦の位置がタブ間で共有**(ヘッダ + 3ページが1つの縦 `ScrollView` の中)。「タブを替えると一覧の位置がタブごとに違う」は再現しない。
  SwiftUI に `NestedScrollView` 相当の部品が無く、ページごとに縦 `ScrollView` を持つとヘッダの縮みを連動できないため。
  ページは3枚とも非 lazy(オフスクリーンのページも木に居る)
- **A10 のバーは隠れるとき `opacity(0)` も掛ける**(平行移動だけだとバーの AX 枠が固定領域の echo に重なる)。隠れたバーは木から消える側に倒れている
- **A4 のスワイプボタンの `#id`**(`btn_sw_*`)は `.swipeActions` の `Button` に付けただけ。UIKit が描くボタンへ届くかは未確認。
  届かなければラベル(`アーカイブ` / `削除` / `ピン留め`)で指す
- **A3 の骨組み行**: `.redacted` + 明示の `accessibilityLabel` / `accessibilityIdentifier`。`.disabled(true)` なので押せない
- **A7 の `#field_otp`** は 1pt ではなく箱と同じ高さの `opacity(0.011)`(完全な透明 / 極小だと焦点が当たらない)
- 部品の外部ライブラリは使っていない(すべて SwiftUI / UIKit 標準)

## 既知の性質(E2EX から)

- SwiftUI `Stepper` / `Menu` / `.searchable` の内部は `#id` が届かない。今回の画面では使っていない
- iOS 26 の「コンテンツ上の右払いで戻る」は左から右の横払いを奪う。A4 では `ContentPopGestureDisabler` で切ってある

## ビルド

```sh
cd E2EYAppIOS
./scripts/build-ios.sh    # → dist/ios-simulator/FTE2EYIOS.app
```

`xcodegen` が必要(`brew install xcodegen`)。
