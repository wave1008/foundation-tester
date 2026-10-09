# flick

[in English](flick.md)

指を1回速く動かすだけの生ジェスチャです。画面(または `scrollFrame`)基点の8方向があります。

## 関数

| 関数 | 説明 |
|---|---|
| `flickCenterToTop(scrollFrame:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickCenterToBottom` / `flickCenterToLeft` / `flickCenterToRight` | 画面(または `scrollFrame`)の中央を起点に、その方向の端へ払います。`durationSeconds` の上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます。 |
| `flickLeftToRight(scrollFrame:startMarginRatio:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickRightToLeft` | 端から端へ横方向に払います。`startMarginRatio` は省略時 `scrollRight` 等と同じ既定値(0.2)です。`durationSeconds` の上限は上と同じです。 |
| `flickBottomToTop(scrollFrame:startMarginRatio:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickTopToBottom` | 端から端へ縦方向に払います。`durationSeconds` の上限は上と同じです。 |

**`settle: false`** を渡すと、このコマンドの操作後の「画面が落ち着くまでの待ち」を省きます(次のステップは動いている最中の画面を見ることがあります)。詳細は [tap](./tap_ja.md) 参照。

## 例

```swift
flickLeftToRight()                          // 画面全体で1回だけ速く横に払う
flickCenterToTop(scrollFrame: "#carousel")  // 特定のスクロール可能領域の中で払う
```

## 注意点

- `flick` は**コンテンツを見ないジェスチャ**です。要素が見つかるまで探索して止まる
  `scroll*` と違い、`flick` は単に1回速いストロークを送るだけです。既定の
  `durationSeconds`/`intervalSeconds` は `swipe` より短く、Shirates の flick のタイミングに
  合わせています。
- `scrollableElement` 引数はありません —— 対象領域は [scroll](./scroll_ja.md) と同じく
  `scrollFrame:` のセレクタ式で指定します。
- Shirates の `flickAndGo*` 一族(画面遷移トリガ)や、要素基点の `flickTo*`/`flickOut*` は
  持ちません。
- **`flick` は「端に着いたか」を判定しません。** `scrollToBottom` 等の代わりに flick を
  何回か並べて速く送っても、到達したかどうかは分かりません —— 払った後は自分で到達先を
  検証してください。

### Link
- [index](../../index_ja.md)
