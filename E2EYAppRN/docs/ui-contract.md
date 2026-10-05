# FT E2EY RN アプリ UI 契約(React Native 固有)

**画面構成・`#id`・ラベルの唯一の正は `E2EYAppCMP/docs/ui-contract.md`**(Compose Multiplatform 版)。
このファイルは **React Native 実装固有の部品選択・逸脱点・ビルドだけ**を定義する。

- bundle id / applicationId: `com.ftester.e2ey.rn`
- 表示名: `FT E2EY RN`・ホームのタイトル `E2EY ホーム`
- ディープリンク: 持たない
- 実測環境: RN 0.86.2・TypeScript・New Architecture(Fabric)
- シェル: `@react-navigation/native-stack`。ヘッダのタイトルが `#txt_screen_title`

## 画面 → 使った部品

| 画面 | 部品 | 版 |
|---|---|---|
| A1 入れ子スクロール | core `FlatList` + 横の `FlatList horizontal`(`windowSize={3}` で画面外のカードを木から外す) | RN 0.86.2 |
| A2 反転チャット | core `FlatList inverted` + `maintainVisibleContentPosition`(`minIndexForVisible: 1` + `autoscrollToTopThreshold`)+ `KeyboardAvoidingView` | RN 0.86.2 |
| A3 読み込みの状態 | core `FlatList`(`onScroll` で末尾を判定)+ 灰色の骨組み(無効の `Pressable`) | RN 0.86.2 |
| A4 スワイプの操作 | `react-native-gesture-handler/ReanimatedSwipeable`(右・左のアクション)+ `Gesture.Pan`(返信行) | gesture-handler 2.33.0 / reanimated 4.7.0 |
| A5 選択モード | core `FlatList` + `Pressable`(`onLongPress`・`accessibilityState.selected`) | RN 0.86.2 |
| A6 文中リンク | 入れ子の `Text`(`onPress`・`accessibilityRole="link"`) | RN 0.86.2 |
| A7 PIN と OTP | 透明の `TextInput`(`number-pad`)を箱の上に重ねる + 自前キーパッド | RN 0.86.2 |
| A8 戻るの横取り | `@react-navigation/native` の `usePreventRemove`(+ `beforeRemove`) | native 7.4.1 |
| A9 引き伸ばせるシート | `@gorhom/bottom-sheet`(非モーダルの `BottomSheet`・`snapPoints` 三段・`BottomSheetFlatList`) | 5.2.14 |
| A10 スクロールで隠れるバー | core `FlatList` の `onScroll` + `react-native-reanimated`(`translateY`) | reanimated 4.7.0 |
| A11 折りたたみヘッダとタブ | `react-native-collapsible-tab-view`(`Tabs.Container` + `MaterialTabBar` + `Tabs.FlatList`) | 8.0.1(新規追加・版固定) |
| A12 高さの揃わないグリッド | `@shopify/flash-list` の `masonry`(`numColumns={2}`) | 2.3.2 |

`react-native-collapsible-tab-view` は peer が `react-native-reanimated >= 3.8.1`・`react-native-pager-view`・
`@shopify/flash-list`(すべて既存)で、New Architecture のビルドは通る。**デバイス上の実挙動は未確認**
(動かなければ自前実装へ差し替え、理由をここへ書く)。
`@react-navigation/elements`(`useHeaderHeight`)を直接依存に足した(2.9.43・固定)。

## 契約からの既知の逸脱

- **`#btn_back` は付けない**(ネイティブの戻るボタンをそのまま使う)。native-stack の戻るボタンは
  ネイティブ描画(iOS = `UINavigationBar` 標準・Android = `Toolbar` のナビゲーションアイコン)で `testID` を
  通せない。`headerBackButtonDisplayMode: 'minimal'` でシェブロンだけにしている。a11y ラベルは iOS が前画面の
  タイトル相当・Android が `Navigate up`(ロケール依存)。シナリオは `back()` を使う
- **A8 の確認ダイアログは画面内のオーバーレイ**(`Alert.alert` は `testID` を通せず、`#txt_discard_title` /
  `#btn_discard` / `#btn_keep` を付けられないため)。別ウィンドウのダイアログの witness にはならない
- **A8 の「破棄」** は `usePreventRemove` が横取りした action をそのまま `dispatch` して抜ける
  (`goBack()` を撃つと再び横取りされる)。元の画面への `back=clean|discarded` はモジュール内のストアで渡す
- **A8 の iOS エッジスワイプ**は、`usePreventRemove` が有効な間(パネルが開いている・欄に文字がある)は
  native-stack が止めてから JS の確認へ回す(契約の「理想」の挙動)。欄が空でパネルも閉じていれば素直に戻る
- **A6 の `#row_with_link` は `accessible={false}` の `Pressable`**。`accessible` のままだと iOS は子の `Text`
  (と文中リンク)を 1 要素へ畳み込み、`こちら` が木から消える。代わりに `#row_with_link` 自体は
  a11y 要素にならない可能性がある(Android は `resource-id` が出る想定・iOS の `accessibilityIdentifier` は未確認)。
  文中リンクの `#id` は付けられない(入れ子の `Text` に `testID` は通らない)ので**ラベルで指す**
- **A6 の入れ子リンクの a11y**: iOS は Fabric の `RCTParagraphComponentView` が `accessibilityRole="link"` の
  入れ子 `Text` を子要素として出す想定、Android は `ClickableSpan` の仮想ノード。**どちらも実機未確認**
- **A7 の `#pin_len`** は 4 桁目で `pin=…` を出したあと表示を空へ戻すので `pin_len=0` に戻る
- **A7 の箱 `#otp_box_N`** は `Text`(空のときは半角空白)。実体は箱に重ねた透明(`opacity: 0.02`)の
  `TextInput` `#field_otp` で、箱の上のタップはこの欄が受ける
- **A9 の畳んだ状態でキューは木に居ない**(中身を `index` で出し分け: 畳み = ミニプレーヤー / 半分・全開 =
  見出し + キュー)。三段(64pt / 50% / 100%)は `@gorhom/bottom-sheet` の `snapPoints`。
  `sheet=` は `onChange`(スナップが決まった時点)で更新する。`handleComponent={null}`(ハンドルを持たない)
- **A9 の `#mini_player`** は `accessible={false}` の `Pressable`(子のボタンを畳まないため)。a11y 要素にならない
  可能性がある(押すときは座標に当たる)
- **A10 のバーは `translateY` で画面外へ動かすだけ**(木から消えない)。`bars=` は止まった時点(スクロールが
  300ms 止まったとき)の値
- **A11 の `#tab_*` は `MaterialTabItem` の `testID` に渡す**(ラベルは `accessibilityLabel`)。左右に払って
  切り替わるページは `react-native-pager-view` が持つ
- **A12 の `FlashList` は仮想化される**ので、60 枚のうち木に居るのは窓の分だけ

## 引き継いだ RN 特有の設定・罠

- 各画面の「accessible な祖先が子を 1 要素へ畳む」(iOS)に注意する。`TaggedButton`/`ListRow` は内側の `Text` を a11y から
  隠し、`accessibilityLabel` だけをラベルにする。ボタンの中に別の押せる要素を入れる画面(A6・A9)は
  外側を `accessible={false}` にする
- `StyleSheet.absoluteFillObject` は RN 0.86 に無い(`position: 'absolute'` と 4 辺で書く)
- `react-native-gesture-handler` は `index.js` の最上部で import する(公式要件。他 import より
  後だと Android でネイティブビュー登録が間に合わないことがある)
- `react-native-reanimated` v4 は worklet 変換を `react-native-worklets` に委譲しており、
  babel.config.js のプラグインは `react-native-worklets/plugin`(`react-native-reanimated/plugin`
  は後方互換の re-export)。`react-native-worklets` は reanimated の peer dependency だが
  **package.json の直接 dependency としても明示しないと iOS の自動リンクが解決できない**
  (`pod install` が `Unable to find a specification for RNWorklets` で落ちる。CocoaPods の
  autolinking は package.json の直接依存を走査するため、間接依存のままだと拾われない)
- `MainActivity.onCreate` は `super.onCreate(null)` で呼ぶ(react-native-screens の既知の作法。
  `savedInstanceState` をそのまま渡すと Fragment 復元でネイティブ側の画面スタックと JS 側の
  状態がずれることがある)
- iOS 27 SDK 対応(`SceneDelegate` 導入・Podfile の deployment target 15.0 引き上げ)は
  `E2EAppRN` と同じ対処を踏襲(E2EAppRN/docs/ui-contract.md §D・E 相当)

## ビルド

```sh
npm ci
cd ios && pod install && cd ..
scripts/build-ios.sh      # dist/ios-simulator/FTE2EYRN.app (Release)
scripts/build-android.sh  # dist/android/ft-e2ey-rn-release.apk (Release)
```
