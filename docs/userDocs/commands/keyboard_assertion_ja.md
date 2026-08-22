# keyboardIsShown, keyboardIsNotShown

ソフトキーボードの表示/非表示を検証します。開閉はアニメーションを伴うため、どちらも `timeout` までポーリングします。

## 関数

| 関数 | 説明 |
|---|---|
| `keyboardIsShown(timeout:)` | ソフトキーボードが表示されていることを検証します。 |
| `keyboardIsNotShown(timeout:)` | ソフトキーボードが非表示であることを検証します。 |

## 例

```swift
tap("#email")
keyboardIsShown()
tap("#login_btn")
keyboardIsNotShown()
```

## 注意点

- **「非表示」を確定できるのは iOS in-app エンジンと Android だけです。** iOS の xcuitest エンジンは
  「キーボードを見た」か「不明」しか言えず、非表示を確定できません。このエンジンでは
  `keyboardIsNotShown` は必ず失敗します — 見えていれば「keyboard is still shown」、
  見ていなければ「cannot determine the keyboard state」というメッセージになります
  (不明を非表示と読んで嘘の成功にしない設計です)。

### Link
- [index](../index_ja.md)
