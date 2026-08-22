# verify

複数のアサーションを1つの報告単位にまとめます。

## 関数

| 関数 | 説明 |
|---|---|
| `verify(message) { }` | ブロックを実行し、`message` を名前とする1ステップ(check)として記録します。ブロック内で `exist` / `notExist` / text・value・id・this・app 系の検証コマンドが1つ以上実行され、すべて成功すれば passed になります。 |

## 例

```swift
verify("注文情報が正しい") {
    select("#order_id").textIs(注文番号 ?? "")
    exist("#order_total")
}
```

## 注意点

- **アサーションが0個の場合は passed でも failed でもなく `inconclusive`(結論なし)になります。**
  検証したつもりで何も検証していないことに気付かせるための仕組みです。`inconclusive` はシナリオを
  中断せず、レポートとログには ❓ とともに理由が出ます。
- ブロック内のコマンドが失敗した場合は、通常どおりシナリオが中断します。

### Link
- [index](../index_ja.md)
