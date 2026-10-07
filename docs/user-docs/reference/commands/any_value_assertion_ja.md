# 任意の値の検証(thisIs, thisContains, …)

[in English](any_value_assertion.md)

デバイスに触れない値(API 応答・計算結果など)を検証します。文字列・数値・`Bool`・Optional に
直接生え、失敗すれば他のコマンドと同じく1ステップとして記録され、シナリオを中断します。

## 関数

| 肯定 | 否定 | 判定 |
|---|---|---|
| `thisIs(expected, strict:)` | `thisIsNot(expected, strict:)` | 一致 / 不一致 |
| `thisIsTrue()` | `thisIsFalse()` | `Bool` |
| `thisIsNotEmpty()` | `thisIsEmpty()` | 空でない / 空文字 |
| `thisIsNotBlank()` | `thisIsBlank()` | 空白のみでない / 空白のみ(空文字も blank) |
| `thisContains(expected)` | `thisContainsNot(expected)` | 部分一致 |
| `thisStartsWith(expected)` | `thisStartsWithNot(expected)` | 前方一致 |
| `thisEndsWith(expected)` | `thisEndsWithNot(expected)` | 後方一致 |
| `thisMatches(pattern)` | `thisMatchesNot(pattern)` | 正規表現 |
| `thisMatchesDateFormat(format)` | — | `DateFormatter` の書式 |
| `thisIsGreaterThan(other)` / `thisIsGreaterThanOrEqual(other)` | — | 数値の大なり(以上)(数値に解釈できなければ失敗) |
| `thisIsLessThan(other)` / `thisIsLessThanOrEqual(other)` | — | 数値の小なり(以下)(数値に解釈できなければ失敗) |

`thisIs` / `thisIsNot` の `strict:`(既定 `false`)は、`textIs` などと同じ比較規則の切り替えです。
既定では目に見えない文字(ゼロ幅など)を無視して比較し、`strict: true` で一切正規化しません。
他の関数に `strict:` はありません。

## 例

```swift
let 合計 = select("#total").text     // 画面から読んだ値や httpRequest の応答など
合計.thisContains("1,200")
合計.thisStartsWith("合計")
(10 * 3).thisIs(30)
"2026/07/27".thisMatchesDateFormat("yyyy/MM/dd")
在庫数.thisIsGreaterThan(0)
```

### Link
- [index](../../index_ja.md)
