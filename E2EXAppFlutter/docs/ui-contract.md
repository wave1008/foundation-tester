# FT E2EX Flutter アプリ UI 契約

**画面構成・`#id`・表示ラベル・echo 文字列は `E2EXAppCMP/docs/ui-contract.md` と共通**
(このファイルが載せるのは Flutter 実装固有の差分だけ)。tag 定数は `lib/tags.dart` に集約する
(値は master 契約の表と byte 一致)。

- bundle id / applicationId: `com.ftester.e2ex.flutter`(他の SUT と共存できる)
- 表示名: `FT E2EX Flutter`
- ディープリンクは持たない
- シナリオ: `TestProjects/E2EX-Flutter/scenarios/`

## Flutter で `#id` を出すための必須設定

`E2EAppFlutter/docs/ui-contract.md` の「`SemanticsBinding.instance.ensureSemantics()`」
「`Semantics(identifier:)` を `MergeSemantics` で畳む(`tagged()`)」「Slider に `MergeSemantics`
を被せると iOS の a11y ツリーが丸ごと空になる」がそのまま前提になる。`lib/widgets.dart` の
`tagged()` / `taggedContainer()` はそちらと同じ手当て。

## 画面ごとの実装部品

| 画面 | Flutter 部品 |
|---|---|
| シェル | `Scaffold` + `AppBar` + `go_router`(ルート文字列は英語スラッグ。例 `/pager`) |
| ホーム | `ListView` の `ListTile`(`tagged(..., button: true)`) |
| ページャ | `PageView`(`taggedContainer` で `#pager_main` を非マージ付与) |
| ボトムシート | `showModalBottomSheet(isScrollControlled: true)` + 固定高さ(画面の70%)の `Column` + `ListView.builder` |
| メニュー | `PopupMenuButton`(`onCanceled` で dismissed)+ M3 `DropdownMenu`(`labelWidget` で選択肢に id) |
| 日付ピッカー | `showDatePicker`(M3 カレンダー) |
| ドロワー | `Scaffold.drawer` + `Drawer` + `ListTile`、`onDrawerChanged` で `drawerOpen` |
| 引っ張って更新 | `RefreshIndicator` + `ListView.builder`(1.0秒の疑似更新) |
| スナックバー | `ScaffoldMessenger.showSnackBar` + `SnackBarAction` |
| グリッド | `GridView.builder`(`SliverGridDelegateWithFixedCrossAxisCount(3)`) |
| スワイプで削除 | `Dismissible(direction: DismissDirection.endToStart)` |
| タブ | 固定 `TabBar`(3)+ `TabBar(isScrollable: true)`(12)+ M3 `NavigationBar`(3) |
| アニメーション | `AnimatedOpacity`(1500ms)+ `AnimatedSwitcher`(800ms) |
| ツールチップ | `Tooltip`(`triggerMode: longPress`)+ `IconButton` |
| チップと分割ボタン | `FilterChip` / `ActionChip` / `SegmentedButton` / `RangeSlider` |
| 検索バー | `SearchAnchor.bar` + `suggestionsBuilder` |
| 引数付き遷移 | `go_router` の `/detail/:id`(`state.pathParameters`) |

## Compose 版(master 契約)との差分

- **Popup 系は「別ウィンドウ」ではない**: Compose(Android)の `Popup`/`Dialog`/`ModalBottomSheet`/
  `DropdownMenu` は別ウィンドウなので中身に id を付け直す必要があるが、Flutter の
  `showModalBottomSheet`・`PopupMenuButton`・`DropdownMenu`・`Tooltip`・`SearchAnchor` はすべて
  同じ `Overlay`(同一の a11y ツリー)上に乗る。**再付与は不要**。
- **ボトムシートは `isScrollControlled: true` + 固定高さ(70%)を採用**(`DraggableScrollableSheet`
  ではなく)。シートの高さ自体が指の動きで伸縮しないほうが、中の30行 `ListView` のスクロール量が
  シナリオにとって安定するため
- **DatePicker の OK/Cancel・日付セルには id を付けられない**(組み込みダイアログの内部)。
  ラベル `"OK"` / `"Cancel"` で指す前提(master 契約と同じ扱い)
- **`date=null` はこの SUT では再現できない**: Flutter の `showDatePicker` は選択を未選択(null)
  に戻す UI を持たず、OK は常に選択済みの日付を返す。null が返るのはキャンセル/バリアタップの
  ときだけなので、この SUT では `date=cancel` にしか到達しない
- **Snackbar の Duration.LONG/SHORT 相当の列挙が無い**: 契約の「約10秒」「約4秒」を
  `Duration(seconds: 10)` / `Duration(seconds: 4)` と直書きしている
- **Tooltip の吹き出し本文(`#txt_tooltip` 相当)に id を付けられない**: `Tooltip.message` /
  `richMessage` はカスタム Widget を差し込めない。文言 `これはツールチップです` はラベルで
  指す前提とする
- **`#txt_tooltip_state` は近似値**: Flutter の `Tooltip` には「今表示中か」を読む public API が
  無い(Compose の `tooltipState.isVisible` に相当するものが無い)。`onTriggered` で shown に、
  そこから `showDuration`(2秒に固定)と同じ長さだけ待って hidden に倒す近似で出している。
  実際の非表示アニメーション完了の直接観測ではない
- **`#txt_anim_target` は非表示中もツリーに残る**: Compose の `AnimatedVisibility` は非表示化で
  composition から外すが、Flutter 側は `AnimatedOpacity` で透明度だけを 1500ms かけて動かし、
  要素自体は常時マウントのまま。要素の有無ではなく `#txt_anim_visible` の値で判定すること
- **RangeSlider は未検証の予防的措置**: Slider に `MergeSemantics` を被せると iOS の a11y
  ツリーが丸ごと空になる罠(E2EAppFlutter で実測済み)と同種の構造(増減の子ノード)を
  RangeSlider も持つ可能性があるため、確認していないが同じ手当て(単体 `Semantics`)を
  先回りで適用している
- **NavigationBar の3destination の id はアイコン側に付与**: `NavigationDestination.label` が
  `String`(Widget を差し込めない)ため、`icon:` に `tagged()` を渡している。タップ判定は
  destination 全体のヒット領域内なので、アイコンの矩形をタップすれば destination 全体を
  押したことになる
- **`#field_fruit` / `#field_search` は非マージの `Semantics` で id を重ねる**
  (`taggedContainer`)。`MergeSemantics` で畳むと `DropdownMenu`/`SearchAnchor` 内部の
  フィールド・アイコンのノードが1つに潰れてしまうため

## 第2弾の実装(Flutter)

画面構成・`#id`・表示ラベル・echo 文字列は `E2EXAppCMP/docs/ui-contract-wave2.md` と共通(このファイルが
載せるのは Flutter 実装固有の差分だけ、という第1弾からの方針は第2弾も同じ)。

| 画面 | Flutter 部品 |
|---|---|
| 伸縮するヘッダ | `CustomScrollView` + `SliverAppBar(pinned, expandedHeight: 200)` + `FlexibleSpaceBar` + `SliverList` |
| 貼り付く見出し | `CustomScrollView` + セクションごとの `SliverMainAxisGroup([SliverPersistentHeader(pinned), SliverList])` |
| 時刻ピッカー | `showTimePicker`(`initialEntryMode: dial`・`MediaQuery(alwaysUse24HourFormat: true)`) |
| ダイアログ | `AlertDialog`(アラート・入力つき)/ `showCupertinoModalPopup` + `CupertinoActionSheet`(アクションシート)/ `Dialog.fullscreen`(全画面) |
| 長押しメニュー | `GestureDetector(onLongPressStart)` + `showMenu`(押した座標に表示) |
| 並べ替え | `ReorderableListView`(既定のドラッグハンドル) |
| 入力の種類 | `TextField`(keyboardType/obscureText/minLines)+ `FocusNode` + Material `Autocomplete<String>` |
| FAB | `Scaffold.floatingActionButton`(`FloatingActionButton` + `.extended`)+ `BottomAppBar` の `IconButton` ×2 |
| 展開するリスト | `ExpansionTile` ×3 |
| ステッパーと進捗 | `IconButton` ×2(+/-)+ `AnimationController` 駆動の `LinearProgressIndicator` + `CircularProgressIndicator` |
| 無限スクロール | `ListView.builder` + `ScrollController` リスナー(末尾 200px 手前で 0.8 秒後に追加読み込み) |
| ピンチで拡大 | `InteractiveViewer`(`TransformationController` から scale を読み取る) |
| 固有部品 | `Hero`(画面遷移)/ `CupertinoSwitch` / `CupertinoPicker` / `PlatformView`(`UiKitView`・`AndroidView`) |

### 逸脱・実装メモ

- **時刻ピッカーの OK/Cancel は Flutter 既定の英語ローカライズ("OK"/"Cancel")のまま**:
  showDatePicker と同じ制約(組み込みダイアログの内部ボタンには id を付けられず、日本語化もしていない)。
  `Tags.btnTimeOk` / `Tags.btnTimeCancel` は契約の id を記録するためだけに定義してあり未使用
  (`Tags.btnDateOk`/`Tags.btnDateCancel` と同じ扱い)
- **ダイアログの `#btn_toast` は実装しない**: Flutter に Android の `Toast` に相当する OS 標準 API が無い
  (契約どおり省略。トースト相当の体験は第1弾のスナックバー画面が既にカバーしている)
- **アラート/入力つき/アクションシートの内部ボタンには id を付けない**: 契約表がこれらに `#id` を
  与えていない(全画面ダイアログの保存/閉じるには `#id` があるので付ける)。ラベル
  ("OK"/"キャンセル"/"保存"/"写真を撮る"/"ライブラリから選ぶ")で指す前提
- **貼り付く見出しは `SliverMainAxisGroup` でセクションごとに区切る**: `SliverPersistentHeader`
  (pinned)を単純に並べるだけだと複数の見出しが同時に積み重なって全部貼り付く。
  `SliverMainAxisGroup` で1セクション分の見出し+行をひとまとめにすることで、
  「そのセクションがビューポート内にある間だけ」その見出しが貼り付く(見た目上1つの見出ししか
  貼り付かない)動作になる
- **展開するリストは `ExpansionTile` 全体でなく `title` だけに id を付ける**: `tagged()`(`MergeSemantics`)
  を `ExpansionTile` 全体に被せると、開いた子(`#item_*`)まで1ノードに畳まれてタップ対象が壊れる
  (第1弾の Slider と同種の罠)。`title:` の Text 単体にだけ `tagged()` を使い、子は個別に `tagged()` する
- **並べ替えは `onReorderItem`(`onReorder` は本 Flutter 版で非推奨)**: `onReorderItem` は削除後の
  index で `newIndex` を渡すため `oldIndex`/`newIndex` の手動補正が不要(`onReorder` は補正が要った)
- **FAB は2つとも明示的な `heroTag` を持つ**: 同一画面に複数 `FloatingActionButton` を置くと既定の
  hero tag が衝突してアサーションで落ちるため
- **固有部品(`PlatformView`)はネイティブ側にビューファクトリの登録コードが要る**:
  iOS は `ios/Runner/AppDelegate.swift` の `NativeLabelViewFactory`(`FlutterPlatformViewFactory`)、
  Android は `android/app/src/main/kotlin/.../NativeLabelView.kt` の `NativeLabelViewFactory`
  (`PlatformViewFactory`)+ `MainActivity.configureFlutterEngine` での `registerViewFactory` 呼び出し。
  view type は両OS共通で `native_label_view`。iOS は `UILabel.accessibilityIdentifier = "native_label"`、
  Android は `res/values/ids.xml` で定義した `R.id.native_label` を `TextView.id` に設定して
  resource-id で指せるようにしている
- **固有部品(`Hero`)はトリガーのボタンでなく別の視覚要素に付ける**: ボタン自体を `Hero` で包むと
  遷移の見た目が不自然になるため、正方形の色付きコンテナ(装飾のみ・id 無し)を `Hero` にし、
  `#btn_hero` は隣に置いた別ボタンとして遷移だけを担う。遷移先の `HeroDetailScreen`
  (ルート `/native/hero`)が同じ `Hero` tag(`heroTag`。`native_screen.dart` からエクスポート)を
  持つ拡大版を表示し、`#btn_hero_back` で戻る
- **入力の種類: 数字キーパッド欄は `FilteringTextInputFormatter.digitsOnly` で数字以外を弾く**
  (`keyboardType: TextInputType.number` だけでは物理キーボード等からの非数字入力を防げないため)

## ビルド

```sh
cd E2EXAppFlutter
./scripts/build-ios.sh        # → dist/ios-simulator/FTE2EXFlutter.app
./scripts/build-android.sh    # → dist/android/ft-e2ex-flutter-debug.apk
```

`scripts/build-ios.sh` は `E2EAppFlutter` と同じ理由(`flutter build ios --simulator` が
universal アーキテクチャ要求で必ず落ちる)で `xcodebuild` を arm64 固定で直接叩く。
`IPHONEOS_DEPLOYMENT_TARGET` も 15.0 に上げてある(Xcode 27 は 15.0 未満をエラーにする)。
