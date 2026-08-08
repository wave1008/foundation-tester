# FT E2E React Native アプリ UI 契約

**画面構成・`#id`・表示ラベルは `E2EAppCMP/docs/ui-contract.md`(Compose Multiplatform 版)と共通**。
同じシナリオを各 SUT に当てて比較できるよう、値は byte 一致させてある。
このファイルは **React Native 実装固有の差分だけ**を定義する。
tag 定数は `src/tags.ts` に集約する(値は共通契約の表と byte 一致)。

- bundle id / applicationId: `com.ftester.e2e.rn`(他の SUT と共存できる)
- `#txt_about_app` は `app=com.ftester.e2e.rn`
- シナリオ: `TestProjects/E2E-RN/scenarios/`(**platform 未指定 = ios/android 両方で回す**)
- 実測環境: RN 0.86.2・TypeScript・**New Architecture(Fabric)**・iPhone 17 Pro iOS 27.0 Simulator /
  Pixel 9 Android 15 Emulator(2026-08-08)。旧 Architecture(Paper/Bridge)は未検証

## RN で `#id` を出すための必須設定

1. **RN 0.65 以降**(この版から `testID` が Android の `resource-id` に露出する。それ以前は iOS の
   `accessibilityIdentifier` にしか出ない)
2. **`testID` を対象要素へ直接付けるだけでよい**。Flutter の `Semantics(identifier:)` +
   `MergeSemantics` のような追加ラッパーは不要 —— RN は view 単位の a11y delegate が testID を
   そのまま流す
3. **`Modal`(ダイアログ)内も同じ経路で id が引ける**(両 OS・両エンジンで実測済み。Compose の
   「ダイアログだけ id 全滅」問題は RN には無い)

## React Native 固有の罠(すべて実測で踏んだもの)

### A. 縦スクロール容器は iOS だけラッパーと実 scroll ノードが分かれる

`FlatList` に付けた `testID`(`#list_rows` 等)は iOS では `RCTScrollView` のラッパー要素(型
`other`・非 scrollable)に付き、実際にスクロールするノードは**同 frame の別要素**に割れる。
Android は `scrollView id=list_rows scroll` の理想形でそのまま出る。
→ **ホスト側で「同一 frame の id 付きラッパー + 匿名 scroll ノード」を統合する正規化**を入れて
両エンジン・両 OS で吸収している(design.md §「スコープ `祖先 >> 子孫`」参照)。SUT 側の対処は不要。

### B. Android は Pressable の内側 Text が別ノードとして出る(ツール側で畳み込み済み)

`TaggedButton`(`src/ui.tsx`)の子 Text は `importantForAccessibility="no-hide-descendants"` +
`accessibilityElementsHidden` で隠しているが、Android はブリッジが a11y 非重要ビューも含めて
採るため、**button と同ラベルの staticText が別ノードで残る**(iOS は同じ隠蔽指定で単一ノード化
できている)。2026-08-08 からホスト側が「button に frame ごと内包される同ラベル・無 id の
staticText」を畳む(`SnapshotDedupe.dropLabelTwinsInsideButtons`。ラベルの曖昧注記と
`.staticText[n]` の水増しが解消)。**id 付き・別ラベル・枠外のテキストは畳まない**ので、
実テキストを button に重ねる設計は従来どおり見える。

### C. iOS in-app は id 付き Text が2重化することがある

`testID` を持つ `Text` が「id 付き staticText + 同 frame・同ラベルで id 無しの staticText」の対で
出ることがある(iOS in-app エンジンのみ)。→ ホスト側(uiFramework=uikit のときだけ)で既存の
`SnapshotDedupe` を適用して畳む。SUT 側の対処は不要。

### D. UIScene ライフサイクル未採用のまま Xcode 27 でビルドすると起動時に落ちる

RN 0.86 のテンプレートは `AppDelegate` が直接 `window` を生成する旧来の構成で、iOS 27 SDK は
これを `EXC_BREAKPOINT`(`NoSceneLifecycleAdoption`)で落とす。`ios/FTE2ERN/AppDelegate.swift` に
`SceneDelegate` を追加し、`window` の生成と RN 起動を `scene(_:willConnectTo:options:)` 側へ
移してある(`Info.plist` の `UIApplicationSceneManifest` と対)。

### E. CocoaPods の一部 Pod が宣言する deployment target が Xcode 27 でエラーになる

`@react-native-async-storage/async-storage` 等の一部 Pod は `IPHONEOS_DEPLOYMENT_TARGET = 13.0` を
宣言するが、Xcode 27 は 15.0 未満をビルドエラーにする。`ios/Podfile` の `post_install` で
全ターゲットの deployment target を 15.0 未満なら 15.0 へ引き上げている。

### F. `FlatList` は仮想化されるため画面外行は木に無い

スクロール探索の既定前提どおり(他 SUT と同じ)。iOS は `removeClippedSubviews` を明示している
(既定 `false`。既定のままだと先読み行が実座標のままツリーに残り scroll-leftover 警告の対象になる)。
初期表示で `#row_06` まで完全可視の契約は `initialNumToRender`/`windowSize` を絞って両 OS で満たす
(`src/screens/ScrollScreen.tsx`)。

### G. ダイアログは `Modal` で背景ツリーと同居する

xcuitest は Modal の内容だけを見るが、**in-app は背景ツリーと同居した状態で見える**(両 OS)。
シナリオがダイアログ内要素を掴むときは背景の同名要素と衝突しないラベル/`#id`を使うこと
(共通契約のダイアログ画面のタグはこの前提で設計済み)。

### H. 【未解決フレーク】横 FlatList のスクロール探索が要素を飛び越すことがある(iOS xcuitest)

シナリオ 07 S0090(`#carousel_tags` 内の `#tag_15` を方向継承で探索)が **5 回中 2 回**、
「7 スワイプ動いた後に content no longer moved」で落ちた(2026-08-08 実測)。フリング 1 回の
移動量がタグ数個ぶんあり、`removeClippedSubviews` の横 FlatList では目標を**飛び越して右端に
到達**する形とみられる(縦の「飛び越し」witness と同族)。単発観測のため tool 側の対処は
していない — 再発したら反復 10 周で頻度を採ってから判断する(docs/verification.md の規律)。

## 型語彙(実測表)

| 要素 | RN iOS(xcuitest / in-app 一致) | RN Android |
|---|---|---|
| Pressable + role button | `button` | `button` |
| Text | `staticText` | `staticText` |
| `Switch` | `switch`(value 0/1) | `switch` |
| Checkbox(role checkbox) | `other`(value に `"checkbox, unchecked"` 等) | `checkBox` |
| Radio(role radio) | `other` | `checkBox`(**`radioButton` にならない**) |
| Slider(role adjustable・自前描画) | `other`(value `"50%"`) | `slider`(range 0-100) |
| `TextInput` 単一行 | `textField` | `textField` |
| `TextInput` secureTextEntry | `secureTextField` | `secureTextField` |
| `TextInput` multiline | `textView` | `textField` |

**入力欄がネイティブ SUT(SwiftUI/View)と同型になるのが RN の特徴**(`RCTUITextField` は
`UITextField` 派生・`ReactEditText` は `EditText` 派生のため)。CMP(iOS は入力欄が全部 `textView`)とも
Flutter(in-app では `other`)とも違い、新しい型分岐をホスト側に足す必要が無かった
(design.md §「入力欄は『エンジン間で揃える』ところまでが担保」)。

`type` / `pressEnter` は両 OS・両エンジンで既存経路がそのまま通る(controlled `TextInput` の値
巻き戻しは起きない。in-app の `pressEnter` も UIKit 経路で発火し、Flutter のような engine 私有 API
は不要。ime カウンタは実測 +1・本文に改行は入らない)。

## セレクタ画面の序数(シナリオ 04 が依存)

見えている Button のツリー順は他の SUT と**同じ**:
戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。
→ 3番目の『項目』= `.button[6]`。**Android は button の内側に同ラベルの staticText が別に出るが
(上記罠B)、Button の序数には影響しない**。

## WebView 画面(SUT 固有の実測)

`react-native-webview` は実 `WKWebView`(iOS)/ `android.webkit.WebView`(Android)を使う。

- **iOS in-app は読みは DOM 経路で通るが、合成タッチが Web 側のハンドラに届かない**
  (2026-08-08 実測: リンクタップが無反応のまま成功に見える)。そのため RNCWebView は
  interop マーカー(`WebViewDOMSnapshot.isInteropHosted`・版59)に登録してあり、
  **hybrid では WebView 画面ごと XCUITest へ委譲される**(CMP/Flutter と同じ扱い)。
  利用者の書き分けは要らない
- Android/iOS とも `#id` が効かない・`.link` と `.staticText` が分かれて出る等の**規約は
  `E2EAppCMP/docs/ui-contract.md` の WebView 節と共通**(RN 固有の追加規約は無い)

## ビルド

```sh
cd E2EAppRN
./scripts/build-ios.sh        # → dist/ios-simulator/FTE2ERN.app
./scripts/build-android.sh    # → dist/android/ft-e2e-rn-release.apk
```

**両方とも Release 構成でビルドする**(RN の Debug 構成は Metro が常時接続している前提で
JS バンドルをアプリに同梱しないため、Metro を切り離す E2E では使えない)。
iOS は `main.jsbundle` をビルドフェーズで同梱、Android は `assembleRelease` を使うが
`signingConfigs.debug` で署名する(無署名 APK はインストール不可なため)。

**iOS 27 SDK の罠2つ**(上記 D・E)は `xcodebuild` を通すために必須の変更で、
`scripts/build-ios.sh` 自体はシミュレータ向けに `ARCHS=arm64` 固定で叩くだけの単純なラッパー。
