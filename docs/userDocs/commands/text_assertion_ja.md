# テキストの検証

要素のラベル(表示テキスト)を検証します。

**対象は常に「直前に掴んだ要素」で、これらのコマンドにセレクタは渡しません。**
まず `select`(または `exist` / `tap` など)で要素を掴み、そのうえで検証します。
次の3つの書き方はまったく同じ意味で、記録されるステップもデバイス往復の回数も同じです。

```swift
select("#msg").textIs("完了")                 // 戻り値へチェーン
select("#msg"); lastElement.textIs("完了")    // lastElement を明示
select("#msg"); textIs("完了")                // 暗黙(直前に掴んだ要素)
```

引数は `(期待値, timeout:)`(肯定形は `requireVisible:` も取ります)。セレクタを渡す形はありません
— `textIs("#msg", "完了")` はコンパイルできません。

## 関数

| 肯定 | 否定 | 判定 |
|---|---|---|
| `select(selector).textIs(expected, timeout:, requireVisible:, strict:)` | `textIsNot(expected, timeout:, strict:)` | 完全一致 |
| `textContains(expected, timeout:, requireVisible:, strict:)` | `textContainsNot(expected, timeout:, strict:)` | 部分一致 |
| `textStartsWith(expected, timeout:, requireVisible:, strict:)` | `textStartsWithNot(expected, timeout:, strict:)` | 前方一致 |
| `textEndsWith(expected, timeout:, requireVisible:, strict:)` | `textEndsWithNot(expected, timeout:, strict:)` | 後方一致 |
| `textMatches(pattern, timeout:, requireVisible:, strict:)` | `textMatchesNot(pattern, timeout:, strict:)` | 正規表現(部分一致。全体一致は `^…$`) |
| `textMatchesDateFormat(format, timeout:, requireVisible:)` | — | `DateFormatter` の書式文字列(例: `"yyyy/MM/dd"`) |
| `textIsNotEmpty(timeout:, strict:)` | `textIsEmpty(timeout:, strict:)` | 空でない / 空 |

上記はすべて `exist` / `select` の戻り値にチェーンでき、直前に掴んだ要素に効く1引数の
暗黙形(自由関数)も持ちます。

## 例

```swift
select("#msg").textIs("完了")

exist("#total")
    .textStartsWith("合計")
    .textEndsWith("円")
```

## 注意点

- **比較は「見た目が完全に一致していれば同じ」**という規則です。ゼロ幅・双方向制御・
  ソフトハイフンなど目に見えない文字は無視しますが、見た目が違うものは別物として扱います
  — 半角スペースと全角スペースは違いますし、連続空白・両端の空白も残ります。
  `strict: true` を渡すと一切正規化しません(`textIs("完了", strict: true)`)。
  不一致で落ちたときは、失敗文が正規化比較・厳密比較のどちらなら一致したかを言います。
- 要素は在る前提で、`timeout` までかけて値の変化を待ちます。値が更新されるのを待つ用途にも使えます。
- 否定系と空判定(`textIsNot`・`textIsEmpty` など)は可視性を見ません
  — 「見えていないこと」は画面照合できないためです。
- **これらに `scroll:` はありません。** 静止した画面を検証するためのコマンドなので、
  対象を先に `select(selector, scroll: .down)` などでビューに入れてから検証してください。
- `exist(…)` / `select(…)` / `lastElement` にチェーンした検証は、まず掴んだ時点の値で判定します。
  それで条件を満たしていればデバイスを見に行きません(ステップは記録され、説明に
  `(from the grabbed value)` が付きます)。満たしていなければ従来どおり `timeout` までポーリングします。

### Link
- [index](../index_ja.md)
