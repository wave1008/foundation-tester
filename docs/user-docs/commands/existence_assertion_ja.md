# exist, notExist, countIs

セレクタで指した要素の存在・不在・件数を検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `exist(selector, timeout:, requireVisible:, scroll:, maxSwipes:)` | 存在検証です。マッチした要素を返すので、text・value・id の検証をチェーンできます。実行プロファイルで `falsePositiveCheck: true` の run では、実際に見えていることも確認します。 |
| `notExist(selector, timeout:, scroll:, maxSwipes:)` | 要素が消えるまで待ちます(初回で不在なら即成功)。`scroll:` を指定すると、その方向へスクロールしながら探し、見つかった時点で不在検証を失敗させます。スクロールしても見つからなければ、通常どおり現在のビューポートでの消滅待ちに進みます。 |
| `countIs(selector, count, timeout:)` | ツリー上の候補件数を検証します。可視性は見ません。`\|\|` は和集合の総数(重複は1度だけ)。ラベルで数えるときは型で絞ってください(例: `.button&&追加` — ボタンと内側のラベルは別要素として両方マッチするため)。 |
| `existWithScrollDown(selector, maxSwipes:)` / `existWithScrollUp(selector, maxSwipes:)` | `exist(selector, scroll: .down)` / `exist(selector, scroll: .up)` のエイリアスです。`maxSwipes` だけを取ります。左右方向のエイリアスはありません。 |
| `existWithoutScroll(selector, timeout:, requireVisible:)` | `withScrollDown` / `withScrollUp` / `withScrollRight` / `withScrollLeft` ブロックの内側でも、現在の画面だけで存在検証します。 |

`waitForDisplay` / `waitForClose` はスクロールせずに要素の表示/消滅を待つコマンドです。
[wait](./wait_ja.md) を参照してください。

## 例

```swift
expectation {
    exist("#welcome_text||Welcome")
    notExist("#loading_spinner")
    countIs("#row||", 5)
}
```

## 注意点

- `exist` の戻り値は text・value・id の検証にチェーンできます。
  [テキストの検証](./text_assertion_ja.md)・[値の検証](./value_assertion_ja.md)・
  [idIs](./id_assertion_ja.md) を参照してください。
- `exist` / `notExist` / `countIs` は常にセレクタを取ります。複数の要素を解決しうるコマンドなので、
  直前に掴んだ要素へ暗黙に効く形はありません。

### Link
- [index](../index_ja.md)
