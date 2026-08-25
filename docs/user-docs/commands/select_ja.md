# select

デバイスを操作せずに要素を掴みます。値の読み出しや検証コマンドの起点に使います。

## 関数

| 関数 | 説明 |
|---|---|
| `select(sel, timeout:requireVisible:scroll:maxSwipes:)` | 要素を掴みます。`exist` と違い**検証ではない**ので、レポートに検証ステップとして残りません。値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使います。掴めなければ失敗させず**空要素**を返すので、呼び出し側は `.isEmpty`/`.isNotEmpty` で分岐します。在ることを保証したいなら `exist` を使ってください。`requireVisible: false` で可視性照合自体を外せます。 |
| `selectWithScrollDown(sel, requireVisible:maxSwipes:)` / `selectWithScrollUp` / `selectWithScrollRight` / `selectWithScrollLeft` | `select(sel, scroll: .down)` などの糖衣です。 |
| `selectWithoutScroll(sel, timeout:requireVisible:)` | `withScrollDown { }` ブロックの中でも、現在画面だけで解決します。 |
| `lastElement` | **直前に掴んだ要素**(引数なし)。要素を1つに定めて解決したコマンド(`select`/`exist`/`tap`/`type`/`waitForDisplay`/テキスト・値の検証など)が通るたびに差し替わります。値は掴んだ時点の凍結値で、その後のスクロールやタップでは更新されません。 |

## 例

```swift
select("#btn_ok").textIs("OK")

let e = select("#txt_total")
if e.isNotEmpty {
    // 見つかった場合の処理
}
```

掴んだ要素から値を読み出す方法(`.text` / `.value` / `.id`)は
[値の読み出し](./reading_values_ja.md)を参照してください。

## 注意点

- `select` 単体でシナリオを失敗させることはありません。見つからなければ空要素になるだけで、
  例外は投げられません。失敗しうるのはチェーンした検証コマンド(`.textIs(...)` 等)側です。
- `lastElement` は各 `scene` の開始時点で空になり、掴めなかったコマンドが通ると空要素で
  上書きされ、一度も掴んでいなければ空(+警告)になります。

### Link
- [index](../index_ja.md)
