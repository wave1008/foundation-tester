# idIs

直前に掴んだ要素の identifier を検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `select(selector).idIs(expected, timeout:, strict:)` | 要素の identifier が `expected` と一致することを検証します。対象は直前に掴んだ要素で、暗黙形 `idIs(expected, timeout:, strict:)` としても書けます。 |

比較規則はテキストの検証と同じ「見た目が完全に一致していれば同じ」です([テキストの検証](./text_assertion_ja.md)参照)。
`strict: true` で正規化を無効化できます。

## 例

```swift
exist("#login_btn").idIs("login_btn")
select("#row_01"); idIs("row_01")
```

### Link
- [index](../index_ja.md)
