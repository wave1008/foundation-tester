# FT E2EY Flutter アプリ UI 契約

**画面構成・`#id`・表示ラベル・echo 文字列は `E2EYAppCMP/docs/ui-contract.md` と共通**
(このファイルが載せるのは Flutter 実装固有の差分だけ)。tag 定数は `lib/tags.dart` に集約する
(値は母体契約の表と byte 一致)。

- bundle id / applicationId: `com.ftester.e2ey.flutter`
- 表示名: `FT E2EY Flutter`(Dart パッケージ名 `ft_e2ey_flutter`)
- ディープリンクは持たない
- シナリオ: `TestProjects/E2EY-Flutter/scenarios/`

## Flutter で `#id` を出すための必須設定

- `main()` で `SemanticsBinding.instance.ensureSemantics()`(無いと a11y ツリーが空)
- `Semantics(identifier:)` は iOS = accessibilityIdentifier / Android = resource-id。単体では「id だけのノード」と
  「label だけのノード」に割れるので `MergeSemantics` で畳む(`lib/widgets.dart` の `tagged()`)
- **子孫を個別ノードのまま残す場所**(スクロール容器・リンクを含む文・Pinput)は `tagged()` を使わず
  `taggedContainer()`(`container: true, explicitChildNodes: true`)か非マージの `Semantics` を使う
- Slider 系に `MergeSemantics` を被せると iOS の a11y ツリーが丸ごと空になる(E2EY には Slider は無い)

## 画面 → 使った部品

| 画面 | Flutter 部品 | 依存 |
|---|---|---|
| シェル | `Scaffold` + `AppBar` + `go_router`(戻るは `Navigator.maybePop` = PopScope を通す) | go_router 18.0.1 |
| ホーム | `ListView` の `ListTile` | |
| A1 入れ子スクロール | 縦 `ListView.builder` の中に横 `ListView.builder`(`#list_nested` / `#shelf_i` は `taggedContainer`) | |
| A2 反転チャット | `ListView.builder(reverse: true)` + `ScrollController` + `TextField` | |
| A3 読み込みの状態 | `ListView.builder` + `ScrollController` 末尾検知 + `Timer`。骨組みの行は `Semantics(enabled: false, excludeSemantics: true)` | |
| A4 スワイプの操作 | `Slidable`(`startActionPane` / `endActionPane` + `DismissiblePane` = full swipe)+ 返信行は `GestureDetector` の自前ドラッグ | flutter_slidable 4.0.3 |
| A5 選択モード | `ListTile(onLongPress)` + `Semantics(checked:, selected:)` | |
| A6 文中リンク | `Text.rich` + `TextSpan(recognizer: TapGestureRecognizer)`(行は `InkWell` の中に入れ子) | |
| A7 PIN と OTP | `Pinput.builder`(箱を `#otp_box_N` で自前描画)+ 自前キーパッド(`ElevatedButton`) | pinput 7.0.0 |
| A8 戻るの横取り | `PopScope(canPop:, onPopInvokedWithResult:)` + `showDialog(AlertDialog)` | |
| A9 引き伸ばせるシート | `DraggableScrollableSheet(snap: true, snapSizes: [0.5])`(畳む = min・全開 = max の三段) | |
| A10 スクロールで隠れるバー | `UserScrollNotification` の向き + `AnimatedSlide`(3つとも画面外へ平行移動) | |
| A11 折りたたみヘッダとタブ | `NestedScrollView` + `SliverAppBar(pinned)`(`bottom: TabBar`)+ `TabBarView`(左右の払いで切り替わる) | |
| A12 高さの揃わないグリッド | `MasonryGridView.count(crossAxisCount: 2)` | flutter_staggered_grid_view 0.7.0 |

## 契約からの逸脱・実装メモ

- **A8: 欄に文字がある間(canPop=false)は iOS のエッジスワイプが無効になる**。`PopScope` は iOS の
  戻りジェスチャ自体を止めるだけで、横取りして確認ダイアログを出すことはできない。パネルが開いている間も同じ
  (パネルだけ閉じる動作は `#btn_back` と Android の戻るでだけ成立する)。空の欄・パネル閉のときはエッジスワイプで
  そのまま戻る(`back=clean`)
- **A8: `#btn_back` は `Navigator.maybePop()`**。`context.pop()` は PopScope を迂回するので使わない
- **A4: 払いきった行(full swipe)の閾値は flutter_slidable の既定**(`DismissiblePane.dismissThreshold = 0.75`)。
  契約の「行幅の大半」に当たる。ボタンは `CustomSlidableAction` の中に id を付けた子を入れている
- **A9: 畳んだ状態でもキューの行は木に残りうる**(`ListView` のキャッシュ領域。シートの高さ 64 に収まらない行は
  画面外の座標で居る)。`#txt_sheet_state` は最後の extent 通知から 250ms 経った時点の値(停止の通知が無い)
- **A9: ミニプレーヤー(畳み)と全開用の見出しは `SliverPersistentHeader(pinned)` の同じ枠を state で差し替える**
  (`sheet=collapsed` のときだけ `#mini_player`)。キューを送っても見出し(畳むボタン)は貼り付く。
  `#list_queue` は `taggedContainer` を被せた同じ `CustomScrollView`
- **A10: 隠れる向きは `UserScrollNotification.direction`**(reverse = 隠す・forward = 出す)。`#txt_bars_state` は
  `ScrollEndNotification` の時点の値
- **A11: `header=collapsed` は外側のスクロール量がヘッダ折りたたみ量(144)に届いた時点**。契約の
  「一部でも見えていれば expanded」とは toolbar の下に残る分だけ差がありうる
- **A6: リンクの子ノードに `#id` は付けない**(`TextSpan` に Semantics を差し込めない)。`利用規約` 等の
  ラベルで指す。段落 `#txt_terms` / `#txt_post` は非マージの `Semantics(identifier:)` で付けている
- **A6: 折り返さない幅は保証していない**。`fontSize: 13` で最小サポート画面の 1〜2 行に収めているが、
  端末の文字サイズ設定で変わる
- **A7: `#field_otp` は `Pinput` を包む `taggedContainer`**(`Pinput` 内部の入力欄に直接 id を付けられない)。
  箱 `#otp_box_N` は `Pinput.builder` の各箱へ `tagged()` で付けた表示専用ノード
- **A7: `#pin_dots` は 0 桁のとき空文字**(ラベルが空のノードになる)
- **A3: 骨組みの行は静的な灰色の帯**(シマーのアニメーションは付けない = 常時再描画でアイドル待ちを妨げない)
- **A2: 着信で最下部から離れている間は、足した行の高さ(56)ぶん offset を送って位置を保つ**

## ビルド

```sh
cd E2EYAppFlutter
./scripts/build-ios.sh        # → dist/ios-simulator/FTE2EYFlutter.app
./scripts/build-android.sh    # → dist/android/ft-e2ey-flutter-debug.apk
```

`flutter build ios --simulator` は universal アーキテクチャ要求で必ず落ちるため、`build-ios.sh` は
`xcodebuild` を arm64 固定で直接叩く。
