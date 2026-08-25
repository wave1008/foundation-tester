# 値の読み取り(lastElement, .text, .value, .id)

掴んだ要素に対して検証するだけでなく、その要素自身の値(ラベル・値・identifier)を読み取る方法です。

## 掴んだ要素の値を読む(`.text` / `.value` / `.id`)

`exist`(や `select`)の戻り値からは値そのものも取り出せます。期待値をシナリオに書き切れないとき
— 注文番号を控えて後の画面で照合する、画面に出ている合計を計算に使う、といった用途に使います。

```swift
var 注文番号: String?

scene(2, "注文を確定して注文番号を控える") {
    action { tap("#btn_order") }
    .expectation {
        select("#order_id").textStartsWith("注文番号:")   // 先に値を確定させてから読む
        注文番号 = exist("#order_id").text
    }
}
scene(3, "確認画面にも同じ注文番号が出る") {
    action { tap("#tab_orders") }
    .expectation { select("#confirm_order_id").textIs(注文番号 ?? "") }
}
```

- `.text` は要素の表示テキスト(ラベル)、`.value` は値、`.id` は identifier です。
- 値は **`exist` が照合した時点のもの**で、`.text` を読んでも画面を取り直しません
  (追加のデバイス往復もステップ記録も発生しません)。最新の値が要るなら `exist` を書き直します。
- **更新途中の画面をいきなり読まないでください。** 要素自体は先に存在するので `exist` は即座に
  成功し、古い値を掴みます。上の例のように `textIs` / `textStartsWith` 等で値を確定させてから
  読んでください。
- **要素を掴めなかったとき・失敗後にスキップされたとき・dry-run では `nil`** になります
  (「掴めなかったのに値が読める」状態を作らないためです)。
- **掴めたかどうかは `.isEmpty` / `.isNotEmpty` で見てください(`.text == nil` では代用しません)**
  — ラベルを持たない要素(アイコンだけのボタンなど)を掴んだときも `.text` は空になるため、
  `.text == nil` では「掴めていない」と誤判定します。

```swift
let e = select("#total")
if e.isNotEmpty { 合計 = e.text }   // 無い・見えていなければ空要素なので読まない
```

- 検証ステップをレポートに残したくないときは、`exist` の代わりに `select` を使ってください。
  `select` は掴むだけで可視性照合の対象にもなりません(`select("#total").text`)。

## 直前に掴んだ要素(`lastElement`)

戻り値を受けていなくても、直前に掴んだ要素は `lastElement` で読めます。

```swift
select("#total")
lastElement.text.thisContains("1,200")     // 変数に受けなくても読める
tap("#order_btn")
lastElement.idIs("order_btn")              // 操作コマンドも掴んだ要素を差し替える
```

- **差し替えるのは、要素を1つに定めて解決したコマンド**(`select` / `exist` / `tap` / `type` /
  `waitForDisplay` / text・value・id・state の検証など)です。`notExist` と `countIs` は
  **差し替えません**(要素を1つに定めないため)。セレクタを取らないコマンド(`swipe` /
  `launchApp` 等)も差し替えません。
- `.text` / `.value` / `.id` は `exist` の戻り値と同じく**掴んだ時点の凍結値**です。
  掴んでから読むまでにスクロール・タップを挟むと古い値を読みます。値を読むのは掴んだ直後にするか、
  離れた場所で使うなら変数に受けてください(`let e = select(…)`)。
- **掴めなかったコマンドは空要素で上書きします**(前の要素が残ると、別の要素の値を
  「今掴んだもの」として読んでしまうためです)。**scene を跨ぐと空になります。**
  一度も掴んでいない状態で読むと空要素+警告が出ます。

## チェーンした検証の初回判定(掴んだ値を先に見る)

チェーンした検証(`exist(…).textIs(…)`・`lastElement.textIs(…)`・暗黙形の `textIs(…)`)は、
**まず掴んだ時点の値で判定**します。満たしていればステップは記録されますが、デバイスを見に行きません
(説明に `(from the grabbed value)` が付きます)。満たしていなければ従来どおり `timeout` まで
ポーリングします。

```swift
exist("#total").textIs("1,200")   // 掴んだ値が "1,200" なら往復 0 回
tap("#reload_btn")
lastElement.textIs("1,500")       // 掴んだ値は古い → 取り直して "1,500" になるまで待つ
```

掴んでから検証までの間が空くほど、古い値がたまたま期待に一致して待たずに通ってしまう向きの
誤りが増えます。とくに `lastElement` を掴んだ場所から離れて使うときは注意してください。

### Link
- [index](../index_ja.md)
