# exist, notExist, countIs

セレクタで指した要素の存在・不在・件数を検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `exist(selector, requireVisible:, waitSeconds:, scroll:, maxSwipes:)` | 存在検証です。マッチした要素を返すので、text・value・id の検証をチェーンできます。実行プロファイルで `textVisualCheck: true` の run では、実際に見えていることも確認します。 |
| `notExist(selector, waitSeconds:, scroll:, maxSwipes:)` | 要素が消えるまで待ちます(初回で不在なら即成功)。`scroll:` を指定すると、その方向へスクロールしながら探し、見つかった時点で不在検証を失敗させます。スクロールしても見つからなければ、通常どおり現在のビューポートでの消滅待ちに進みます。 |
| `countIs(selector, count, waitSeconds:)` | ツリー上の候補件数を検証します。可視性は見ません。`\|\|` は和集合の総数(重複は1度だけ)。ラベルで数えるときは型で絞ってください(例: `.button&&追加` — ボタンと内側のラベルは別要素として両方マッチするため)。 |
| `exist(selector, scroll: .noScroll)` | `withScrollDown` / `withScrollUp` / `withScrollRight` / `withScrollLeft` ブロックの内側でも、現在の画面だけで存在検証します。 |

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
- 「実際に見えていること」の確認では、画面に描かれた文字を期待テキストと突き合わせます。
  **先頭だけが描かれている**ときは次のように扱います(テキストの検証・値の検証も同じ)。
  - 末尾に省略記号(`…`)が描かれている → アプリが意図した省略として緑。注記 `text-ellipsized` が付きます
  - 省略記号が無く、描かれたのが期待テキストの半分より多い → 緑。注記 `text-partially-hidden`
    (テキストの一部が隠れています)が付きます
  - 省略記号が無く、描かれたのが半分以下 → 失敗(`most of the text is hidden`)。
    わざと大部分を隠す画面では `requireVisible: false` を使ってください
  - 判定の例(画像つき)は [テキストの視覚検証の判定](../testclass/text_visual_check_ja.md) を参照してください

### Link
- [index](../index_ja.md)
