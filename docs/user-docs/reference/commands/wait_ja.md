# wait, waitForDisplay, waitForClose, waitForSettle

[in English](wait.md)

固定待ちと、要素の出現・消滅、画面の静止を明示的に待つコマンドです。

## 関数

| 関数 | 説明 |
|---|---|
| `wait(秒)` | 固定待ち。小数可。 |
| `waitForDisplay(sel, waitSeconds: 15)` | 要素が表示されるまで待ちます(**スクロールしません**)。戻り値は `FTElement` で、`exist` と同様にチェーンできます。見つからなければシナリオを失敗させます。 |
| `waitForClose(sel, waitSeconds: 15)` | 要素が消えるまで待ちます(**スクロールしません**)。`sel` は省略できません(直前セレクタを再利用する省略形はありません)。 |
| `waitForSettle(sel?, quietSeconds:, throwsException: true, waitSeconds: 15)` | 画面(`sel` を渡せばその要素の枠)の画素が `quietSeconds` のあいだ1つも変わらなくなるまで待ち、続けてアクセシビリティの木が追いつくまで待ってから `true` を返します。戻り値は `Bool` です(`@discardableResult`。`if` の条件に使えます)。詳細は下の「waitForSettle」。 |

## 例

```swift
tap("#submit")
waitForDisplay("#confirmation_toast", waitSeconds: 10)
waitForClose("#loading_spinner", waitSeconds: 15)
wait(0.5)     // セレクタで待てない整定のときだけ(アニメ中の座標ずれ等)

flickCenterToBottom()
waitForSettle()                    // スクロールの慣性が完全に止まるのを待つ
findImage("[Camera Icon]").tap()   // 静止した画面から画像を読む
```

## 注意点

- **要素の出現待ちは既に暗黙です** —— 操作は解決を再試行し(`waitSeconds:` を省くと約 0.7 秒)、検証はタイムアウトまでポーリング
  再判定するので、`exist()` の前に `wait()` を置くのは冗長です。待ちが足りなければ固定の
  `wait()` を足すのではなく、コマンドの `waitSeconds:`(小数可)を上げてください。
- **`wait()` はセレクタで待てない整定のための最後の手段です**(アニメ中に座標がずれる等)。
  `waitForDisplay` / `waitForClose` の代わりにはなりません。
  画面が止まるのを待ちたいときは、固定の `wait()` ではなく `waitForSettle` を使ってください。
- **`waitForDisplay` の判定は `exist` と同じ可視性込み**です(コマンド名 displayed の意味に
  沿わせています)—— `exist` の `requireVisible: false` に当たる逃げ道はありません。覆われ
  検出を外したまま待ちたい場合は `exist(sel, requireVisible: false, waitSeconds: 15)` を使って
  ください。
- `waitForDisplay` / `waitForClose` はどちらもスクロールして探しません。画面外にある可能性が
  あるなら、先にスクロールするか `scrollTo` を使ってください。

## waitForSettle

```swift
@discardableResult
waitForSettle(_ selector: String? = nil, quietSeconds: Double? = nil,
              throwsException: Bool = true, waitSeconds: Double? = nil) -> Bool
```

画面の動きが止まるまで待ちます。**書いたときだけ待ちます** —— 通常の操作(`tap`・`swipe`・`scroll*` など)は
画素の静止を待ちません。絵を読むステップの直前に書いてください。

- 画像の判定(`findImage` / `existImage` / `imageIs`)や、OCR を使うテキストの視覚検証の前
- 画素単位の位置に依存する操作の前
- レポート用のスクリーンショットの前

特に、スクロールやフリックの直後に慣性がまだ内容を動かしているときに効きます。

### 何を待つか

次の2段を、`waitSeconds` の上限の中で順に待ちます。

1. **画像** —— 比べる範囲の画素が `quietSeconds` のあいだ1つも変わらないこと。
2. **木** —— 絵が止まったあと、アクセシビリティの木が追いつくこと(範囲に入る要素だけを比べた木のスナップショットが
   2回連続で同一)。木は絵より遅れることがあり、そのままだと次のステップが古い木で要素を解決してしまうためです。

両方が上限内に済むと `true` を返します。

### 引数

| 引数 | 意味 |
|---|---|
| `selector` | 省略 = 画面全体。渡すとその要素の枠が比べる範囲になります。止まらない物(スピナー・シマーの骨組みなど)を範囲から外したいときは、それを含まない要素を渡します。要素が見つからなければ、ステップは**必ず失敗**します(`throwsException` を参照)。 |
| `quietSeconds` | 画面がこの時間のあいだ変わらなければ「止まった」とみなす**基準**です。範囲は 0.1〜5 秒。省略時の既定はアプリの UI フレームワークで決まります: iOS の Compose Multiplatform(とフレームワークを判定できないとき)は **0.8 秒**、iOS のそれ以外のフレームワークと Android は **0.5 秒**。慣性の終わりに出る描画の間隔の最大の実測(Compose Multiplatform の 1px ずつの這い 650ms・SwiftUI 368ms・Android の負荷時 385ms)に約 2 割の余裕を足した値です。 |
| `waitSeconds` | 待ち全体(`selector` の要素を探す時間 + 画像 + 木)の**上限**です。要素が見つからないときは、この時間まで探してから失敗します。省略時は 15 秒(`waitForDisplay` / `waitForClose` / `appIs` と同じ)。範囲は 0〜60 秒。 |
| `throwsException` | 既定は `true`。`waitSeconds` までに画面(または木)が止まらなかったとき、`true` ならステップが失敗してシナリオを中断し、`false` ならステップは通って注記 `settle-not-reached` を残し、`false` を返します。 |

### 注意点

- **比べる範囲は、常に各辺を 10% ずつ除いた内側です。** スクロールバーやインジケータのフェード、ステータスバー、
  ホームインジケータは、本体の動きが止まったあとも変わり続けるためです(画面全体でも要素の枠でも同じ)。
- **`throwsException: false` が通すのは時間切れだけです。** `selector` の要素が見つからないときは、どちらの値でも
  必ず失敗します。fleetest には、存在しない要素を通せる引数はありません。これは文書化された唯一の例外で、
  このコマンドの時間切れに限ります。
- **失敗文言は事実だけを述べます。** 画像の段は `the screen kept changing for N s (last change at x, y, w×h)`、
  木の段は `the screen was still but the accessibility tree kept changing for N s (changing: …)` です。要素を探すのに
  上限の大半を使い、残りが `quietSeconds` より短かったときは、`only N s of waitSeconds was left after finding the element, …`
  (止まったと確かめる時間が残っていなかった)と出ます。止まらない物が
  原因で失敗するなら、それを含まない `selector` を渡すか、`quietSeconds` / `waitSeconds` を調整してください。
- **判定はブリッジの中で完結し、画像はホストへ出ません。**
  - iOS は、既定の `hybrid` エンジンでも画素の撮影は常に XCUITest ランナーで行います。in-app エンジンが見えるのは
    アプリ自身の描画だけ(キーボード・システムアラート・他のプロセスは写らない)で、アプリの中で撮り続けるとメイン
    スレッドを塞ぐためです。木の段は次のステップを解決するドライバで行います(`hybrid` なら in-app の木)。
    `engine: "inapp"` だけで XCUITest ランナーを持たないデバイスは、`hybrid` か `xcuitest` への切り替えを案内して失敗します。
  - Android は、instrumentation の中で動くブリッジが撮影します。
- MCP の `ft_batch` も `waitForSettle` を同じ引数で受けます。

### Link
- [index](../../index_ja.md)
