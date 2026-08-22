# scroll

コンテンツ基準のスクロールです。要素が見つかるまで探索する・1画面ぶん送る・端まで送る、の3種類があります。

## 関数

| 関数 | 説明 |
|---|---|
| `scrollTo(sel, direction: .down, maxSwipes: 8, containerInference:)` | 要素が見つかるまでスクロールします(見つかったら成功。タップはしません)。 |
| `scrollDown(repeat: 1)` / `scrollUp` / `scrollRight` / `scrollLeft` | 1画面ぶんスクロールします(`repeat:` 回繰り返します)。 |
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送ります(画面が変化しなくなるまで)。`maxSwipes` は暴走を止める上限で、上限で打ち切るとステップに注記が付きます。 |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | ブロック内の `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` を**すべてスクロール探索**にします(明示の `scroll:` があればそちらが優先)。**`notExist` は意味が変わります** —— 探索中に見つかった時点で失敗になります。 |
| `withoutScroll { … }` | 外側の `withScroll*` を打ち消し、ブロック内は現在画面だけで解決します。 |
| `withoutContainerInference { … }` | ブロック内のすべてのコマンドで、容器の推測に依存する補正(後述)を止めます。 |
| `tapWithScrollDown(sel, maxSwipes:)` 等(4方向) | `tap(sel, scroll: .down)` の別名です。 |
| `tapWithoutScroll(sel, timeout:)` | `withScroll*` の中でも、この1コマンドだけスクロールしません。 |
| `existWithScrollDown(sel, maxSwipes:)` / `existWithScrollUp` | `exist(sel, scroll: .down)` の別名です。 |
| `existWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで存在検証します。 |
| `selectWithScrollDown(sel, maxSwipes:)` 等(4方向) | `select(sel, scroll: .down)` の別名です。 |
| `selectWithoutScroll(sel, timeout:requireVisible:)` | `withScroll*` の中でも現在画面だけで解決する `select` です。 |

**`*WithScroll*` の別名は `maxSwipes:`(`select` 系は `requireVisible:` も)しか取らない糖衣です。**
`timeout:` や `holdSeconds:` も渡したいときは本体の `scroll:` 引数を使ってください
(`tap(sel, scroll: .down, timeout: 2)`)。`existWithScrollLeft`/`Right` を置いていないのも
同じ理由で、`exist(sel, scroll: .left)` と書けば足ります。

## スクロールさせたい領域: `scrollFrame:`

`scrollFrame:`(および `startMarginRatio:` / `endMarginRatio:`)は `scroll*` / `scrollToBottom`
等 / `scrollTo` の引数で、`withScroll*` は `scrollFrame:` のみ取ります。実際にスクロールさせたい
領域をセレクタ式で指定するもので、画面に複数のスクロール可能領域がある(固定ヘッダ+
スクロールするリスト、等)ときに必要です:

```swift
scrollTo("#row_40", scrollFrame: "#list_rows")
```

- **省略時は画面中央基準の全画面スクロール**になり、マージン指定も無視されます。
- `withScrollDown(scrollFrame: "#list") { }` に渡すと、ブロック内のすべての探索がその領域を
  引き継ぎます。
- **領域は解決できたが中の何も動かない場合**、スワイプ自体は送られますがステップに注記が
  付きます(`the specified scrollFrame is not scrollable`。マージンで動かせる幅が潰れた場合は
  `resolved but leaves nothing to move`)。
- **領域が画面に1件も無い場合は、スワイプを1本も送らずに失敗します** —— これは `scrollTo`
  の探索だけでなく `scroll*` / `scrollTo*Edge` 系 / `flick*` / `withScroll*` 配下の探索すべてに
  当てはまります。**`select` 系だけは例外**で、掴めなければ空要素を返す契約が優先されます。

## レポートに出る注記

失敗ではなく観測です:

| 注記 | 意味 | 気にするべきか |
|---|---|---|
| `stopped at the limit of N (may not have reached the edge yet)` | `maxSwipes` で打ち切った = 端に着いたとは限らない | **する**。`maxSwipes` を増やすか、そもそも端に着けない画面かを疑う |
| `the screen did not settle (poll limit)` | スワイプ後 600ms 待っても画面の動きが止まらなかった(慣性が長い等)。操作自体は送られている | 通常は不要。同じ箇所で毎回出るなら、静止前の座標でタップして flake る余地があるので調べる価値がある |
| `fell back to XCUITest` | in-app エンジンで実行できずフォールバックした(1回あたり数百 ms 遅い) | 通常は不要。多発するなら実行プロファイルのエンジン選択を見直す |

## 端送りの速さはエンジンで決まる

`scrollToBottom` 等は「1本振る → 木を読んで動きが止まったか見る」の繰り返しです。**1回の
送りでどれだけ進むか、そもそも往復が要るか**はエンジンで違います:

| エンジン | 1回の送り | 長文の所要 |
|---|---|---|
| iOS in-app(UIKit/SwiftUI・WebView) | 端まで一度に寄せる(`contentOffset` を直接動かす。ジェスチャも慣性も無い) | 文書の長さに依存しない |
| Android の WebView | CDP でページを一発で飛ばす(使えなければジェスチャへ落ちる) | 文書の長さに依存しない |
| iOS in-app(Compose / Flutter) | 1回 = 1ページ(刻み幅を選べない API) | ページ数に比例 |
| iOS xcuitest | 実スワイプ(約1.1画面のフリング) | ページ数に比例 |
| Android(ネイティブ) | 実スワイプ(約1.2画面のストローク) | ページ数に比例。既定の `maxSwipes: 50` では届かない文書もある |

実ジェスチャのエンジンで長文を送るときは `maxSwipes` を上げてください。`flick*` を並べて
速くしようとするのは代用になりません —— flick は端に着いたかどうかを判定しないため
([flick](./flick_ja.md) 参照)。

## 例

```swift
tap("設定", scroll: .down)          // 折り返しの下にある項目を探索してからタップ
withScrollDown {
    tap("#row_40")                  // 書かなくても探索される
    existWithoutScroll("#header")   // 固定ヘッダは現在画面で確認
}
```

## 容器の推測に依存する補正

`tap`/`scrollTo` などの座標解決は、見切れ判定・掴み直し・救済ドラッグ・見えている部分を撃つ
座標補正・壊れた座標の候補除外といった「容器の推測」に依存する補正を行います。既定で有効
ですが、想定外の画面構成(独自のスクロールコンテナ実装など)で補正が裏目に出るときだけ切れます。
3段階のどこで切るかを選べます:

| 単位 | 方法 |
|---|---|
| run 全体(**最上位の殺しスイッチ**) | 環境変数 `FT_CONTAINER_INFERENCE=off`(下の3つより優先し全部無効にします) |
| 1コマンド | `tap(sel, containerInference: false)` / `scrollTo(sel, containerInference: false)` |
| ブロック | `withoutContainerInference { … }`(`tap`/`exist`/`select` など全コマンドに効きます) |
| 実行プロファイル全体 | 実行プロファイルの `containerInference: false` |

環境変数を除けば、優先順位は 明示引数 > ブロックの文脈 > 実行プロファイルの既定 です。

### Link
- [index](../index_ja.md)
