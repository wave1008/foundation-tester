# repeatWhileCanSelect, doUntilTrue

セレクタが解決できる限りブロックを繰り返す、または任意の条件が満たされるまで繰り返します。

## 関数

| 関数 | 説明 |
|---|---|
| `repeatWhileCanSelect(sel, max: 10, waitSeconds: 0) { }` | セレクタが解決できる限りブロックを繰り返します。件数不定の一括操作(不定数のカードを閉じる等)に。上限 `max` への到達は失敗にしませんが記録には残ります。 |
| `doUntilTrue("説明", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { 条件 }` | `条件`(`() async throws -> Bool`)が true になるまで繰り返します。セレクタで表現できないアプリ・外部の状態待ち専用です(要素の出現待ちには使いません。それには各コマンドの `timeout:` を使います)。throw したらリトライせず即座に失敗します。 |

## 例

```swift
repeatWhileCanSelect("#dismiss_card", max: 10) {
    tap("#dismiss_card")
}

doUntilTrue("バックグラウンドジョブの完了", waitSeconds: 10, intervalSeconds: 0.5) {
    select("#job_status").text == "done"
}
```

## 注意点

- `repeatWhileCanSelect` の `max:` はあくまで暴走防止の上限で、「ちょうどこの回数繰り返した」
  ことを検証するものではありません。
- **`doUntilTrue` はセレクタで表現できない状態のためのものです** —— 外部プロセスのポーリング・
  複数回の読み取りから導いた値・現在の画面をまたいで続くアプリ状態など。「要素が出る/消える」
  だけを待ちたいなら `waitForDisplay` / `waitForClose`、またはコマンドの `timeout:` を使って
  ください(そちらは既にポーリングします)。
- `doUntilTrue` の `waitSeconds:` は1ステップの壁時計上限 120 秒を超えられません。それより
  大きな値を渡しても、実際にはそこまで待ちません。
- 条件ブロック内での `throw` はリトライせずそのステップを即座に失敗させます。一時的な読み取り
  エラーではなく、「絶対に true にならない条件」を検出したときのために使ってください。

### Link
- [index](../index_ja.md)
