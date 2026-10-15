# repeatWhileCanSelect, doUntilTrue

[in English](repeat.md)

セレクタが解決できる限りブロックを繰り返す、または任意の条件が満たされるまで繰り返します。

## 関数

| 関数 | 説明 |
|---|---|
| `repeatWhileCanSelect(sel, maxLoopCount: 10, waitSeconds: 0, title:) { }` | セレクタが解決できる限りブロックを繰り返します。件数不定の一括操作(不定数のカードを閉じる等)に。上限 `maxLoopCount` への到達は失敗にしませんが記録には残ります。 |
| `doUntilTrue("説明", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { 条件 }` | ブロックが true を返すまで繰り返します。ブロックの中で `scrollDown()` や `select(...)` などのコマンドを呼べます。throw したらリトライせず即座に失敗します。 |

## 例

```swift
repeatWhileCanSelect("#dismiss_card", maxLoopCount: 10) {
    tap("#dismiss_card")
}

doUntilTrue("バックグラウンドジョブの完了", waitSeconds: 10, intervalSeconds: 0.5) {
    select("#job_status").text == "done"
}

doUntilTrue("「設定」が見えるまで下へ送る") {
    scrollDown()
    return select("設定").isNotEmpty
}
tap("設定")
```

## 注意点

- `repeatWhileCanSelect` の `maxLoopCount:` はあくまで暴走防止の上限で、「ちょうどこの回数繰り返した」
  ことを検証するものではありません。
- 「要素が出る/消える」だけを待ちたいなら、`doUntilTrue` ではなく `waitForDisplay` / `waitForClose`、
  またはコマンドの `waitSeconds:` を使ってください(そちらは既にポーリングし、記録も1ステップで済みます)。
- 1周ごとに `"<説明> #n"` のまとまりとして記録され、最後に結果が1ステップ残ります。ブロックの中のコマンドが
  失敗すると、そこでシナリオが止まります。
- `doUntilTrue` が止まるのは `waitSeconds:` と `maxLoopCount:` だけです(コマンド1つの上限 120 秒は掛かりません)。中の操作の前でステップの減速が待った分は上限から差し引きます。
- 条件ブロック内での `throw` はリトライせずそのステップを即座に失敗させます。一時的な読み取り
  エラーではなく、「絶対に true にならない条件」を検出したときのために使ってください。

### Link
- [index](../../index_ja.md)
