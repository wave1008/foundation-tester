# thisIs 系(画面に依らない値の検証)

デバイスに触れない値(API 応答・計算結果など)を検証します。文字列・数値・`Bool`・Optional に
直接生え、失敗すれば他のコマンドと同じく1ステップとして記録され、シナリオを中断します。

## 関数

| 関数 | 判定 |
|---|---|
| `thisIs(expected, strict:)` / `thisIsNot(expected, strict:)` | 一致 / 不一致 |
| `thisIsTrue()` / `thisIsFalse()` | `Bool` |
| `thisIsEmpty()` / `thisIsNotEmpty()` | 空文字 |
| `thisIsBlank()` / `thisIsNotBlank()` | 空白のみ(空文字も blank) |
| `thisContains(Not)` / `thisStartsWith(Not)` / `thisEndsWith(Not)` | 部分・前方・後方一致 |
| `thisMatches(Not)` / `thisMatchesDateFormat(format)` | 正規表現 / `DateFormatter` の書式 |
| `thisIsGreaterThan(other)` / `thisIsGreaterThanOrEqual(other)` | 数値の大なり(以上) |
| `thisIsLessThan(other)` / `thisIsLessThanOrEqual(other)` | 数値の小なり(以下)(数値に解釈できなければ失敗) |

## 例

```swift
let 合計 = try await fetchTotal()   // procedure { } 内で取得した値など
合計.thisContains("1,200")
合計.thisStartsWith("合計")
(10 * 3).thisIs(30)
"2026/07/27".thisMatchesDateFormat("yyyy/MM/dd")
在庫数.thisIsGreaterThan(0)
```

### Link
- [index](../index_ja.md)
