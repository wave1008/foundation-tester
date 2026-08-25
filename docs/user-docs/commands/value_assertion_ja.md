# 値の検証

要素のラベルではなく**値**(入力欄の内容など)を検証します。構成は
[テキストの検証](./text_assertion_ja.md)と同じです。

**対象は常に「直前に掴んだ要素」で、これらのコマンドにセレクタは渡しません。**
まず `select`(または `exist` / `tap` など)で要素を掴み、そのうえで検証します。

```swift
select("#email").valueIs("test@example.com")              // 戻り値へチェーン
select("#email"); lastElement.valueIs("test@example.com") // lastElement を明示
select("#email"); valueIs("test@example.com")              // 暗黙(直前に掴んだ要素)
```

引数は `(期待値, timeout:)`(肯定形は `requireVisible:` も取ります)。セレクタを渡す形はありません。

## 関数

| 肯定 | 否定 | 判定 |
|---|---|---|
| `select(selector).valueIs(expected, timeout:, requireVisible:, strict:)` | `valueIsNot(expected, timeout:, strict:)` | 完全一致 |
| `valueContains(expected, timeout:, requireVisible:, strict:)` | `valueContainsNot(expected, timeout:, strict:)` | 部分一致 |
| `valueStartsWith(expected, timeout:, requireVisible:, strict:)` | `valueStartsWithNot(expected, timeout:, strict:)` | 前方一致 |
| `valueEndsWith(expected, timeout:, requireVisible:, strict:)` | `valueEndsWithNot(expected, timeout:, strict:)` | 後方一致 |
| `valueMatches(pattern, timeout:, requireVisible:, strict:)` | `valueMatchesNot(pattern, timeout:, strict:)` | 正規表現(部分一致。全体一致は `^…$`) |
| `valueMatchesDateFormat(format, timeout:, requireVisible:)` | — | `DateFormatter` の書式文字列 |
| `valueIsNotEmpty(timeout:, strict:)` | `valueIsEmpty(timeout:, strict:)` | 空でない / 空 |

比較規則はテキストの検証と同じ「見た目が完全に一致していれば同じ」です(`strict:` で無効化可能)。
詳細は[テキストの検証](./text_assertion_ja.md)を参照してください。

## 例

```swift
select("#email").valueIs("test@example.com")
select("#email").valueContains("@example.com")
```

## 注意点

- iOS では、空欄の入力欄が空文字ではなく placeholder の文字列を value として返すことがあります。
  そのような欄では `valueIsEmpty` を避け、`valueIsNotEmpty` や具体的な期待値での検証を使ってください。
- 否定系と空判定は可視性を見ません。また、これらのコマンドに `scroll:` はありません
  — テキストの検証と同じ規則です。
- チェーンした検証は、まず掴んだ時点の値で判定し、それで満たしていなければデバイスをポーリングします。
  詳細は[テキストの検証](./text_assertion_ja.md)を参照してください。

### Link
- [index](../index_ja.md)
