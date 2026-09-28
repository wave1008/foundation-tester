# FT E2EX RN アプリ UI 契約(React Native 定番部品 固有)

**画面構成・`#id`・ラベルの唯一の正は `E2EXAppCMP/docs/ui-contract.md`**(Compose Multiplatform 版)。
このファイルは **React Native 実装固有の差分・使用ライブラリ・逸脱点だけ**を定義する。
`E2EAppRN`(全 SUT 共通契約の SUT)とは別物で、共通契約は持たない。

- bundle id / applicationId: `com.ftester.e2ex.rn`
- 表示名: `FT E2EX RN`
- ディープリンク: 持たない
- 実測環境: RN 0.86.2・TypeScript・New Architecture(Fabric)

## 画面 → ライブラリ対応

| 画面 | 主なライブラリ | 版 |
|---|---|---|
| シェル(ヘッダー・戻る) | `@react-navigation/native` + `native-stack`(`react-native-screens`) | native 7.4.1 / native-stack 7.19.2 / screens 4.28.0 |
| ページャ | `react-native-pager-view` | 6.9.1 |
| ボトムシート | `@gorhom/bottom-sheet`(`BottomSheetModal` + `BottomSheetFlatList`) | 5.2.14 |
| メニュー・果物ドロップダウン | `react-native-paper`(`Menu`, `Menu.Item`, `TextInput`) | 5.15.3 |
| 日付ピッカー | `@react-native-community/datetimepicker` | 8.6.0 |
| ドロワー | `@react-navigation/drawer`(+ `react-native-reanimated` / `react-native-gesture-handler`) | drawer 7.14.2 |
| 引っ張って更新 | `FlatList` + `RefreshControl`(RN core) | RN 0.86.2 |
| スナックバー | `react-native-paper`(`Snackbar`) | 5.15.3 |
| グリッド | `FlatList numColumns={3}`(RN core) | RN 0.86.2 |
| スワイプで削除 | `react-native-gesture-handler`(`Swipeable`) | 2.33.0 |
| タブ | `@react-navigation/material-top-tabs`(`react-native-tab-view` 内蔵)+ `@react-navigation/bottom-tabs` | material-top-tabs 7.7.2 / bottom-tabs 7.19.2 / tab-view 4.3.2 |
| アニメーション | `react-native-reanimated`(`FadeIn`/`FadeOut`/`SlideInDown`/`SlideOutUp`) | 4.7.0(+ `react-native-worklets` 0.13.0) |
| ツールチップ | `react-native-paper`(`Tooltip`, `IconButton`) | 5.15.3 |
| チップと分割ボタン | `react-native-paper`(`Chip`, `SegmentedButtons`)+ `@react-native-community/slider` | paper 5.15.3 / slider 5.2.1 |
| 検索バー | `react-native-paper`(`Searchbar`) | 5.15.3 |
| 引数付き遷移 | `@react-navigation/native-stack`(route params) | 7.19.2 |

`react-native-safe-area-context` 5.10.0(iOS pod)/ 5.5.2(npm 指定範囲)は全画面のシェルが使う。
アイコンは `react-native-vector-icons` を使わず、`PaperProvider` の `settings.icon` と各部品の
`icon` 関数プロパティにカスタム `Text` グリフを渡している(ビルド安定性優先。フォントリンク不要)。

## 契約からの既知の逸脱(すべて実装上の制約による)

### `#btn_back` は付けない(ネイティブの戻るボタンをそのまま使う)

`native-stack`(react-native-screens 経由)の既定の戻るボタンは **ネイティブ描画**
(iOS = `UINavigationBar` 標準の戻るボタン、Android = `Toolbar` のナビゲーションアイコン)で、
`headerLeft` を独自コンポーネントに差し替えない限り `testID` を通せない。差し替えるとネイティブの
スワイプバック・巻き戻りアニメーションの一部特性が変わりうるため、**契約の `#btn_back` は付けず、
ネイティブの戻るボタンをそのまま残す**(タスクの指示どおり)。実際の見え方:
- iOS: `headerBackButtonDisplayMode: 'minimal'` によりラベル無し・シェブロンのみ。
  a11y ラベルは前画面のタイトル("Back"相当)
- Android: `Toolbar` の戻る矢印。a11y の content-description は "Navigate up"(ロケール依存)

### タブ画面: 遷移先スクリーンは空にし、echo は画面外の1箇所にまとめる

`@react-navigation` のタブ系ナビゲータは選択タブごとに**別スクリーンをマウント**する。
CMP 契約の `#txt_tab_content` / `#txt_stab_content` / `#txt_navbar_result` は**単一 `#id`** を
前提にしているため、各タブのスクリーンに echo を置くと同じ `#id` を持つ要素が複数同時にツリーへ
乗りうる。そこで各タブの「画面」は空の `View` にし、`screenOptions`/`Screen` の `listeners.tabPress`
で親(`TabsScreen`)の state を更新し、echo は親の1箇所だけに置いている。タブボタン自体の
`#id` は `tabBarButtonTestID` オプション(react-navigation の公開 API。`tabBarTestID` という
名前ではない)で付けている。

3つの Navigator(固定タブ・横スクロールタブ・ナビゲーションバー)は兄弟として並ぶ。react-navigation は
親 Screen ごとに Navigator を1つしか許さない(`EnsureSingleNavigator`)ため、そのままだと2つめの
登録で `Another navigator is already registered for this container` を投げて**画面ごとクラッシュする**
(iOS は SIGSEGV・Android は `JavascriptException` で強制終了)。各 Navigator を
`NavigationIndependentTree` + 専用の `NavigationContainer` で包み、独立したツリーにして回避している
(react-navigation 公式が案内する「同一画面に複数 Navigator を置く」ときの対処)。

### チップと分割ボタン画面: `#range_slider` は2本の Slider で代替

New Architecture 前提で保守されている「両端つまみの単一レンジスライダー」相当の RN 部品が
見当たらなかった(`@react-native-community/slider` は単一つまみのみ)。`#range_slider` は
2本の Slider(`#range_slider_min` / `#range_slider_max`)をまとめる箱として残し、
実際の操作対象はこの2つ。値は整数に丸め `min<=max` を維持する。

### ツールチップ画面: `#txt_tooltip` / `#txt_tooltip_state` は自前実装、`#btn_tooltip_anchor` は外側の View に置く

`react-native-paper` の `Tooltip` は children を `cloneElement` して `onPress`/`onLongPress`/
`onPressOut` を自分の実装へ差し替える(呼び手が同じ prop 名で渡しても上書きされて呼ばれない)上、
表示中の吹き出しテキストは `Portal` 経由の内部実装で `testID` を通せない。長押しで開く見た目・
挙動そのものは `Tooltip` にそのまま任せ、`#txt_tooltip` / `#txt_tooltip_state` は
祖先 `View` の `onTouchStart`/`onTouchEnd`(responder を奪わない生の touch イベント)で
独立に駆動している(表示までの遅延 500ms は `Tooltip` の既定 `enterTouchDelay` と揃えた値)。

`Tooltip` は children(`IconButton`)を自前の `Pressable`(`accessible` 既定 true)でも包む。
iOS は `accessible=true` な祖先の下を1つの要素へ畳み込むため、`IconButton` 自身に `testID`/
`accessibilityLabel` を付けても木から消える(Android は畳まない。この非対称は既知の逸脱)。
`#btn_tooltip_anchor` / ラベル「情報」は `IconButton` ではなく、それより外側の(`onTouchStart`/
`onTouchEnd` を持つ)`View` を `accessible` にして乗せている。

### 日付ピッカー画面: Android のダイアログ内 OK/キャンセルはネイティブ既定ボタン

Android は `@react-native-community/datetimepicker` が `DatePickerDialog`(完全ネイティブ)を
出す。OK/キャンセルは OS 標準ボタンで `testID` を通せない(CMP 契約の「日付セルはラベルで指す」
と同じ制約がボタンにも及ぶ)。`#btn_date_ok` / `#btn_date_cancel` は **iOS の `display="inline"`
モーダル側だけ**に存在する(タスク指示どおり)。

### ボトムシート画面: `accessible={false}` を明示する

`@gorhom/bottom-sheet` の `BottomSheetModal` は既定で中身全体を `accessible=true` /
`accessibilityRole="adjustable"`(iOS では slider)/ ラベル `"Bottom Sheet"` の**単一要素へ畳み込む**。
iOS はこの1要素だけを木に出し、見出し・選択肢・行がすべて消える(Android は畳まない。既知の逸脱)。
`accessible={false}` を渡してこの既定を止め、中身を個々の要素のまま木へ出している。

### メニュー画面: `#field_fruit` は外側の View に置く・戻るはアプリ側で消費する

`ExposedDropdownMenuBox` 相当の読み取り専用欄は `Pressable`(タップでメニューを開く)の中に
`pointerEvents="none"` な `View` で `TextInput`(`editable={false}`)を包み、タップを
`Pressable` 側へ通している。iOS は非対話(`pointerEvents="none"` → `userInteractionEnabled=false`)な
祖先の下を丸ごと木から外すため、`TextInput` 自身に付けた `testID`/値は消える(Android は消えない。
ツールチップ画面の `accessible=true` 版と表裏の同じ種類の逸脱)。`#field_fruit` / ラベル「果物」/
現在値は `TextInput` ではなく、それを包む `pointerEvents="none"` な `View` 自身を `accessible` にし
`accessibilityValue` で乗せている。

`react-native-paper` の `Menu` は開いている間 `hardwareBackPress` を自前で購読するが、
`onDismiss()` の戻り値を返さないため Android の戻るボタンを「消費した」ことにならず、
react-navigation 側の戻る処理へ伝播して**画面ごと戻ってしまう**(ライブラリの既知の癖)。
`MenuScreen` 側でも `visible` の間だけ `hardwareBackPress` を購読し、`true` を返してメニューを
閉じてから消費する(購読順の都合で `Menu` より後にマウントする本画面側の listener が先に呼ばれる)。

### ダイアログ画面: 全画面モーダルは `SafeAreaView` で自前に避ける

core `Modal` は react-navigation の画面と違い、自分ではセーフエリアを避けない。特に Android は
コンテンツがステータスバーの真下から始まり先頭の要素と重なる(重なった部分は木からも消える)。
`presentationStyle="fullScreen"` の `Modal` の中身は `SafeAreaView` で包んでいる。

### アニメーション画面: カウンタの enter/exit は remount ベース

Compose の `AnimatedContent` に相当する「値変化だけで縦スライドする」API は Reanimated に無いため、
`key={count}` で要素を再マウントし `SlideInDown`/`SlideOutUp` を掛けている。CMP の
`AnimatedContent` と同様、遷移中は**古い要素と新しい要素の `#txt_anim_count` が一瞬共存する**
(800ms の間、値の異なる2つの要素が木に同時に存在しうる。フレームワーク間で共通の特性)。

## RN 特有の設定・罠

- `FlatList` の `onEndReached` は、初期データが1画面に収まっているだけで(1度もスクロールして
  いなくても)「末尾までの距離」がしきい値を下回ったと判定して発火しうる。無限スクロール画面は
  `onScrollBeginDrag` で実際にユーザーがスクロールを始めたことを控えてから `onEndReached` の
  処理を通す(でないと開いた瞬間に2ページぶん読み込まれる)
- 英字専用の入力欄(国名オートコンプリート等)に `autoCorrect`/`keyboardType` を指定しないと、
  日本語ロケール端末の既定キーボード(ローマ字入力)が入力中の文字を仮名候補へ変換し、打った
  文字と違う値になりうる。`autoCorrect={false}` + `autoCapitalize="none"` +
  (iOS は)`keyboardType="ascii-capable"` で素の英字キーボードにする
- `SectionList`/`stickySectionHeadersEnabled` の貼り付く見出しは、次のセクションの見出しが
  上端に来るタイミングで**そのセクションの先頭行に重なる**(見出しの高さぶん)。これは
  貼り付く見出しを持つリスト実装に共通の挙動で RN 固有ではない。直後の行を `#id` で押す
  シナリオは、見出しに隠れない位置までスクロールしてから押す必要がある
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
- vector-icons 不使用: `PaperProvider` の `settings.icon` と各部品の `icon` 関数 prop に
  カスタム `Text` グリフを渡すことで、フォントアセットのネイティブリンクを一切不要にしている

## ビルド

```sh
npm install
cd ios && pod install && cd ..
scripts/build-ios.sh      # dist/ios-simulator/FTE2EXRN.app (Release)
scripts/build-android.sh  # dist/android/ft-e2ex-rn-release.apk (Release)
```

## 第2弾の実装(React Native)

`E2EXAppCMP/docs/ui-contract-wave2.md` の 13 画面を React Native の定番部品で実装する
(画面構成・`#id`・ラベルの唯一の正はそちら。ここは RN 実装固有の部品選択・逸脱だけを書く)。

| 画面 | 主なライブラリ・部品 |
|---|---|
| 伸縮するヘッダ | `react-native-reanimated`(`useAnimatedScrollHandler` + `Animated.FlatList`)。ヘッダは別レイヤー(`position: absolute`)で重ね、スクロール量をヘッダの高さ・文字サイズへ補間する |
| 貼り付く見出し | core `SectionList`(`stickySectionHeadersEnabled`) |
| 時刻ピッカー | `@react-native-community/datetimepicker`(`mode="time"`・`is24Hour`)。Android はネイティブ `TimePickerDialog`、iOS は `display="spinner"` を自前 Modal(OK/キャンセル付き)に載せる |
| ダイアログ | core `Alert.alert`(アラート)/ `react-native-paper`(`Dialog` + `TextInput`。入力つき、両 OS)/ iOS `ActionSheetIOS.showActionSheetWithOptions` + Android `Dialog` + `List.Item`(アクションシート)/ core `Modal`(`presentationStyle="fullScreen"`。全画面)/ Android `ToastAndroid.show`(トースト) |
| 長押しメニュー | `Pressable`(`onLongPress`)+ `react-native-paper`(`Menu`。行をアンカーにする) |
| 並べ替え | `react-native-gesture-handler`(`Gesture.Pan().activateAfterLongPress()`)+ `react-native-reanimated` の自前実装(定番のドラッグ並べ替えライブラリは未採用。理由は下記) |
| 入力の種類 | `react-native-paper`(`TextInput`。`keyboardType`/`secureTextEntry`/`multiline`/`returnKeyType`+`onSubmitEditing`)+ 自前の前方一致候補リスト + `KeyboardAvoidingView` + `ScrollView` |
| FAB | `react-native-paper`(`FAB` + `AnimatedFAB`(`extended`)+ `Appbar`(下部バー)) |
| 展開するリスト | `react-native-paper`(`List.Accordion` + `List.Item`) |
| ステッパーと進捗 | `react-native-paper`(`IconButton` の +/- + `ProgressBar` + `ActivityIndicator`)。進捗は `requestAnimationFrame` で 2 秒ぶんの決定的な値を刻む |
| 無限スクロール | core `FlatList`(`onEndReached`/`onEndReachedThreshold`+`ListFooterComponent`) |
| ピンチで拡大 | `react-native-gesture-handler`(`Gesture.Pinch()` + `Gesture.Pan()` を `Gesture.Simultaneous`)+ `react-native-reanimated`(共有値・`runOnJS` で JS 側へ小数1桁を反映) |
| 固有部品 | `@shopify/flash-list`(`FlashList`)+ core `Modal`(非全画面・transparent)+ core `Switch` |

`@shopify/flash-list` 2.3.2 を新規に追加した(New Architecture 前提の v2 系。iOS 側にネイティブ pod は
増えない = 純 JS + Fabric 標準コンポーネントで完結する。`ios/Podfile.lock` に対応エントリが無いことで確認済み)。
他の画面はすべて既存インストール済みのライブラリ(`react-native-reanimated` / `react-native-gesture-handler` /
`react-native-paper` / `@react-native-community/datetimepicker`)で足りた。

`docs/ui-contract-wave2.md` からの既知の逸脱:

- **並べ替えは定番のサードパーティ製ドラッグ並べ替えライブラリを使わない**。
  `react-native-draggable-flatlist` 等は New Architecture(Fabric)前提での保守状況が薄く未検証のため、
  `Gesture.Pan().activateAfterLongPress()` + `reanimated` 共有値による自前実装で代替する
  (CMP 版の自前実装と同じ方針。契約が候補として明示的に許容している)。しきい値(行の高さの半分)を
  跨ぐたびに配列を並べ替えるので、指を離した位置がそのまま最終順序になる(隣との1回だけの
  入れ替えには丸めない)
- **時刻ピッカーの「入力モードへの切替口」は OS で非対称**。Android の `TimePickerDialog` は
  時計/キーボード切替アイコンを既定で持つため対応不要。iOS の `display="spinner"` にはこの切替口が無い
  (日付ピッカーの OK/キャンセルボタンが iOS 側にしか無いのと同じ種類の非対称)
- **ダイアログの「入力つき」は両 OS で `react-native-paper` の `Dialog` + `TextInput` を使う**。
  `Alert.prompt` は iOS 専用の core API(Android に対応 API が無い)なので両 OS 統一のため採用しない。
  保存/キャンセルのボタンには `#id` が契約に定義されていないためラベルでのみ指す
- **ダイアログの「アクションシート」は Android だけ `react-native-paper` の `Dialog` + `List.Item` で代替**。
  Android にネイティブの action sheet 相当が無いため(契約が候補として挙げている代替を採用)。
  iOS は core `ActionSheetIOS` をそのまま使う
- **`#btn_toast` は Android だけに存在する**(契約どおり)。トーストに対応する core API が iOS に無い
- **固有部品の `FlashList` は仮想化される**ため、50 行のうち実際に木へ乗るのは画面に収まる分だけ
  (`row_i_*` 等ほかの `FlatList` 系画面と同じ特性。契約はこれを妨げない)
