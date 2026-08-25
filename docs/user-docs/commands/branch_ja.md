# ifCanSelect, ios, android

セレクタが解決できたときだけ、または特定の OS のときだけブロックを実行します。

## 関数

| 関数 | 説明 |
|---|---|
| `ifCanSelect(sel, waitSeconds: 0) { }.ifElse { }` | セレクタが解決できたらブロックを実行します。**既定は即時1回判定**(待つなら `waitSeconds:`)。`.ifElse { }` は任意で、解決できなかったときに実行されます。 |
| `ios { }` | 実行中の platform が iOS のときだけブロックを実行します。 |
| `android { }` | 実行中の platform が Android のときだけブロックを実行します。 |

## 例

```swift
tap("#request_location")
ifCanSelect("Appの使用中は許可", waitSeconds: 3) {
    tap("Appの使用中は許可")     // 出なければ何もしない(同意済みの2回目以降)
}.ifElse {
    // 任意: 解決できなかったときに実行される
}

expectation {
    ios { notExist("#ios_only_banner") }
    android { notExist("#android_only_banner") }
}
```

## 注意点

- **`ifCanSelect` は既定で即時1回判定します。** `waitSeconds:`(小数可)を渡すと、その秒数まで
  ポーリングしてから「無い」と判定します。
- 出るか不定のダイアログやバナーの無害化、その場限りの分岐に使います。他のコマンドに
  「出るか不定」を表す個別の引数は無く、この用途は常に `ifCanSelect` で表現します。
- **条件判定も、宣言済みの割り込みを閉じてから答えます。** 対象要素が
  [`irregularHandler`](./irregular_handler_ja.md) の対象に覆われている場合、`ifCanSelect` は
  先にそれを閉じてから判定します — 閉じずに判定すると、覆われた要素が黙って「無い」と
  読まれ、失敗ではなく誤った分岐として現れてしまうためです。
- fleetest は Shirates の `ifTrue` / `ifFalse` / `ifScreenIs` 系を持ちません。
  分岐は意図的に2つだけに絞られています — 既に読んだ値に対する素の Swift `if` と、
  「画面に出ているか」に対する `ifCanSelect` です。
- `ios { }` / `android { }` は、両 OS で共有するシナリオの中に片方の OS だけに当てはまる
  小さな挙動があるとき(共有の `expectation { }` の中で OS 固有のバナーだけ確認する等)に
  使います。

### Link
- [index](../index_ja.md)
