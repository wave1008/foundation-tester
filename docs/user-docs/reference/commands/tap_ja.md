# tap, tapAppIcon

[in English](tap.md)

画面上の要素、または座標をタップします。

## 関数

| 関数 | 説明 |
|---|---|
| `tap(sel, holdSeconds: 0, maxGestureSeconds:containerInference:linkText:settle:waitSeconds:scroll:maxSwipes:)` | セレクタにマッチする最初の要素をタップします。`holdSeconds` を 0 より大きくすると長押しになります(既定 0 = 通常タップ。上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます)。タップ前に対象が操作可能になるまで待ちます(後述)。タップした要素を返すので、検証をそのままチェーンできます(`tap("#btn_ok").textIs("OK")`)。 |
| `tap(sel, linkText: "文字列")` | セレクタで解決した要素の**中で** `linkText` が描かれている位置をタップします。段落の中の文中リンクのように、Compose Multiplatform・Android の View(`ClickableSpan`)・SwiftUI(`AttributedString` のリンク)ではアクセシビリティの木にノードとして出ないものを押すためのものです。位置は、まず木(`linkText` に label か value が一致する子孫。Flutter・React Native はリンクがノードとして出ます)、無ければ要素の画素を OCR で読んで決めます。どちらでも見つからなければステップは失敗し、OCR が読めた行を添えます。要素の中心へ黙って落とすことはありません。どちらで決めたか(`tree` / `ocr`)はステップの注記に残ります。2行に折り返したリンクは OCR では見つかりません。`linkText:` を省くと要素の中心をタップします。 |
| `tap(x: Double, y: Double, holdSeconds: 0, maxGestureSeconds:, settle:)` | 座標を直接タップします。座標は snapshot の `screen` と同じ座標系です(iOS = pt / Android = px。dp ではありません)。セレクタで指せるならそちらを優先してください。iOS の in-app エンジンでは、画面外とソフトキーボードの上の点は失敗になります(in-app はキーを押せません。先に `pressEnter` でキーボードを閉じてください)。スクロール容器で切れて見えていない要素は、frame が点を含んでも押しません。 |
| `tap(sel, scroll: .noScroll)` | `withScrollDown { }` ブロックの中でも、この1コマンドだけスクロールせずにタップします。 |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンをタップします。名前省略時はアプリプロファイルの `appName` が使われます。 |

## 例

```swift
tap("#login_btn||ログイン")
tap("設定", scroll: .down)             // 折り返しの下にある項目を探索してからタップ
tap("#row_03", holdSeconds: 1)         // 長押し
tap("#txt_terms", linkText: "利用規約")           // 段落の中のリンク
tap(x: 120, y: 640)                    // セレクタで指せないときだけ
```

## 注意点

- **`tap` は対象が操作可能になるまで待ってから撃ちます。** 画面が出た直後は、要素は木に
  居るのにまだ触れないことがあります(読み込み中のフォーム・検証が通るまで無効なボタン)。
  `tap` は、対象が `enabled` になるまで、最大で `waitSeconds:`(省略時は 5 秒)まで解決を
  再試行します。それでも有効にならなければ、そのまま撃ちます —— 無効な要素をわざと叩いて
  「反応しない」ことを確かめる書き方も正当に動きます。`&&enabled=false` のようにセレクタで
  状態を明示している場合や `waitSeconds: 0` の場合は待ちません。
- **要素が現れるまでの待ちは短い**: `waitSeconds:` を省くと、要素が見つかるまでの再試行は約 0.7 秒です
  (見つかった後に有効になるまでは、上のとおり最大 5 秒待ちます)。画面遷移の後に遅れて出る要素は
  `tap("#btn", waitSeconds: 5)` のように渡すか、先に `waitForDisplay("#btn")` で待ってください。
  `type` などの他の操作も同じです。
- **`tap` してから `type` する書き方**: `tap("#field")` の後に `type("文字列")` と書く形も使えます。Android で
  `#id` が入力欄の中身ではなく容器側に解決するとき、タップだけではフォーカスが入力欄へ
  移らないことがありますが、その場合は `type` が容器内の唯一の入力欄を名指しして入れ直します。
  詳細は [type](./type_ja.md) 参照。
- **iOS の in-app エンジン:「本物のタッチは別の物に当たる」の注記。** in-app エンジンは要素を直接操作する
  (アクセシビリティの既定動作か、要素の窓へ直接送るタッチ)ので、本物の指では押せない要素にも届くことが
  あります(例: キーボードの上の入力バーの下に潜ったボタン)。要素の枠の中心で本物のタッチが別の view に
  当たるときは、ステップは緑のまま `in-app operated the element directly, but a real touch at the centre of its
  frame lands on another view (<view> at (x, y))` の注記が付きます(機械可読は `inapp-tap-outside-hit-area`)。
  撃ち直しも失敗もしません。枠の中心を押す XCUITest エンジンでは、同じタップが赤になることがあります。
  判定できないとき(全部を1枚の view に描く Flutter など)は何も言いません。文字の部分しか押せない SwiftUI の
  `.plain` のボタンには、代わりに別の注記 `in-app activated the element at its activation point, which is not the
  centre of its frame that a coordinate tap presses (activation point (x, y), centre (x, y))` が付きます(機械可読は
  `inapp-activation-point-off-centre`。SwiftUI と UIKit のアプリだけ)。
- 座標タップは、その位置にアプリが選択可能な要素を1つも公開していないときだけ使います。

  | 用途 | 方針 |
  |---|---|
  | シナリオに残す(長く使う) | セレクタを優先します。座標は最後の手段で、レイアウトが動いた瞬間に別の物を叩きます。 |
  | その場限りの調査 | セレクタを優先しますが、座標のほうが早く解決するならそれでも構いません。 |
- **`settle: false` を渡すと、そのコマンド1回だけ、操作後の「画面が落ち着くまでの待ち」を省きます。** 通常はコマンドが
  画面が落ち着くのを待ってから戻るので(ブリッジの整定の待ちと、操作後に fleetest が行う要素の一覧の比較。待つ時間には上限があります)、
  次のステップは最終的な位置を見られます。`settle: false` ではその呼び出しだけ操作後の待ちを省くので、コマンドは早く戻りますが、
  次のステップは動いている最中の画面を見ることがあります(位置がずれうる)。速さを優先したく、次のステップが最終位置に
  依存しないときに使ってください。結果を確かめるための待ち(入力した文字の読み返し・向きが実際に変わるまでなど)と
  操作の前の待ちは残ります。取るコマンドは `tap`(セレクタ・`x:y:`)・`doubleTap`・`hold`・`type`・`clearInput`・
  `pressEnter`・`hideKeyboard`・`back`・`rotateTo`・`swipe*`・`flick*`・`scroll*`・`scrollTo*`・`pinchOut` / `pinchIn`・
  `gesture` です。引数の位置はコマンド固有の引数の後・`waitSeconds:` の前です。

### Link
- [index](../../index_ja.md)
