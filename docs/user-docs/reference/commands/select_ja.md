# select, lastElement

[in English](select.md)

デバイスを操作せずに要素を掴みます。値の読み出しや検証コマンドの起点に使います。

## 関数

| 関数 | 説明 |
|---|---|
| `select(sel, requireVisible:waitSeconds:scroll:maxSwipes:)` | 要素を掴みます。`exist` と違い**検証ではない**ので、レポートに検証ステップとして残りません。値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使います。掴めなければ失敗させず**空要素**を返すので、呼び出し側は `.isEmpty`/`.isNotEmpty` で分岐します。在ることを保証したいなら `exist` を使ってください。`requireVisible: false` で可視性照合自体を外せます。 |
| `select(sel, scroll: .noScroll)` | `withScrollDown { }` ブロックの中でも、現在画面だけで解決します。 |
| `select(sel).tap(holdSeconds:maxGestureSeconds:)` | 掴んだ要素をタップします。セレクタから引き直してタップするので `tap(sel)` と同じ挙動です。`findImage` / `findImages` で掴んだ要素は、見つけた枠の中心を座標でタップします(見つからなかった画像要素は失敗します)。 |
| `select(sel).type(text, replace:waitSeconds:)` | 掴んだ要素へ入力します。セレクタから引き直すので `type(sel, text)` と同じ挙動です。掴めていない要素では失敗します。`findImage` / `findImages` で掴んだ要素には入力できません(先に `.tap()` してから `type(text)` と書きます)。入力するだけなら `type(sel, text)` と書けば足ります。 |
| `lastElement` | **直前に掴んだ要素**(引数なし)。要素を1つに定めて解決したコマンド(`select`/`exist`/`tap`/`type`/`waitForDisplay`/テキスト・値の検証など)が通るたびに差し替わります。値は掴んだ時点の凍結値で、その後のスクロールやタップでは更新されません。 |

どのコマンドも、セレクタ文字列の代わりに型付きセレクタ `Sel` を取れます([型付きセレクタ](../selector/typed_selector_ja.md))。

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
- [index](../../index_ja.md)
