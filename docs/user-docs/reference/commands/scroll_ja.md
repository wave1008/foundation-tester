# スクロール(scrollTo, scrollDown, withScrollDown, scrollFrame, …)

[in English](scroll.md)

コンテンツ基準のスクロールです。要素が見つかるまで探索する・1画面ぶん送る・端まで送る、の3種類があります。

## 関数

| 関数 | 説明 |
|---|---|
| `scrollTo(sel, direction: .down, containerInference:, lightSettle:, maxSwipes: 8)` | 要素が見つかるまでスクロールします(見つかったら成功。タップはしません)。 |
| `scrollDown(repeat: 1, lightSettle:)` / `scrollUp` / `scrollRight` / `scrollLeft` | 1画面ぶんスクロールします(`repeat:` 回繰り返します)。 |
| `scrollToBottom(lightSettle:, maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | 端まで送ります(画面が変化しなくなるまで)。`maxSwipes` は暴走を止める上限で、上限で打ち切るとステップに注記が付きます。 |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | ブロック内の `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` / `findImage` / `existImage` / `hold` を**すべてスクロール探索**にします(明示の `scroll:` があればそちらが優先)。**`notExist` は意味が変わります** —— 探索中に見つかった時点で失敗になります。 |
| `withoutScroll { … }` | 外側の `withScroll*` を打ち消し、ブロック内は現在画面だけで解決します。 |
| `withoutContainerInference { … }` | ブロック内のすべてのコマンドで、容器の推測に依存する補正(後述)を止めます。 |
| `scroll: .noScroll`(`tap` / `type` / `clearInput` / `select` / `exist` / `notExist` / `findImage` / `existImage` / `hold` の引数) | `withScroll*` の中でも、この1コマンドだけスクロールしません(現在画面だけで解決します)。引数を省いた場合は、ブロックの向きに従います。 |

**`lightSettle:`**(`swipe` / `scroll*` / `scrollToBottom` など / `scrollTo` / `flick*` の引数): 簡易整定モードをこの1回だけ切り替えます。省略すると実行プロファイルの `iosLightSettle` に従い、`true` / `false` を渡すとそちらが優先されます。効くのは iOS の XCUITest ブリッジのスワイプだけです(Android と in-app エンジンでは何もしません)。`swipePointToPoint` / `swipeBy` / `swipeElementToElement` はこの引数を取りません(drag の経路で、簡易整定モードの対象外です)。

**スクロールの指定は、各コマンドの `scroll:` 引数だけで行います。** 向き(`.down` / `.up` / `.right` / `.left`)を渡すと
その方向へスクロールしながら探し、`.noScroll` を渡すと `withScroll*` の中でもスクロールしません。省略した場合は
ブロックの向きに従います(ブロックの外なら現在画面だけ)。`tapWithScrollDown` や `existWithoutScroll` のように
関数名で指定する別名はありません(書くと、コンパイルエラーが `scroll:` を使った書き方を示します)。

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
| `the screen did not settle (poll limit)` | スワイプ後に画面の動きが止まらなかった(慣性が長い等)。操作自体は送られている | 通常は不要。同じ箇所で毎回出るなら、静止前の座標でタップして flake る余地があるので調べる価値がある |
| `fell back to XCUITest` | in-app エンジンで実行できず XCUITest で行った | 通常は不要。多発するなら実行プロファイルのエンジン選択を見直す |

## 端送りの速さ

`scrollToBottom` 等は「1回送る → 画面の動きが止まったか見る」の繰り返しです。Android と、iOS の XCUITest エンジン・
Compose / Flutter では1回の送りが約1ページぶんなので、長い画面では `maxSwipes` を上げてください
(既定の `maxSwipes: 50` では届かない文書もあります)。iOS の UIKit / SwiftUI・WebView と Android の WebView は
端へ一度に寄せるので、文書の長さに依存しません。`flick*` を並べて速くしようとするのは代用になりません ——
flick は端に着いたかどうかを判定しないため([flick](./flick_ja.md) 参照)。

## 例

```swift
tap("設定", scroll: .down)          // 折り返しの下にある項目を探索してからタップ
withScrollDown {
    tap("#row_40")                  // 書かなくても探索される
    exist("#header", scroll: .noScroll)   // 固定ヘッダは現在画面で確認
}
```

## 容器の推測に依存する補正

`tap`/`scrollTo` などの座標解決は、見切れ判定・掴み直し・救済ドラッグ・見えている部分を撃つ
座標補正・壊れた座標の候補除外といった「容器の推測」に依存する補正を行います。既定で有効
ですが、想定外の画面構成(独自のスクロールコンテナ実装など)で補正が裏目に出るときだけ切れます。
3段階のどこで切るかを選べます:

| 単位 | 方法 |
|---|---|
| run 全体 | 環境変数 `FT_CONTAINER_INFERENCE=off`(問題を切り分けるときだけ。下の3つより優先し全部無効にします) |
| 1コマンド | `tap(sel, containerInference: false)` / `scrollTo(sel, containerInference: false)` |
| ブロック | `withoutContainerInference { … }`(`tap`/`exist`/`select` など全コマンドに効きます) |
| 実行プロファイル全体 | 実行プロファイルの `containerInference: false` |

環境変数を除けば、優先順位は 明示引数 > ブロックの文脈 > 実行プロファイルの既定 です。

### Link
- [index](../../index_ja.md)
