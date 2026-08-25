# appIs

フォアグラウンドのアプリを検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `appIs(id, waitSeconds: 15)` | フォアグラウンドのアプリが `id`(iOS は bundle ID、Android は package 名)と一致することを、`waitSeconds` までポーリングしながら検証します。 |

## 例

```swift
tap("#open_maps_btn")
appIs("com.example.maps")
```

## 注意点

- ニックネーム機構は無く、bundle ID / package 名を直接書きます。
- Android は失敗時に実際のフォアグラウンド package 名をメッセージへ含めます。iOS は前面の
  bundle ID を取得する手段が無いため、失敗メッセージには含まれません。

### Link
- [index](../index_ja.md)
