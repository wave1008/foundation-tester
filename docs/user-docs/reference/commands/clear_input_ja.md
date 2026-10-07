# clearInput

[in English](clear_input.md)

入力欄を空にします。

## 関数

| 関数 | 説明 |
|---|---|
| `clearInput()` | フォーカス中の入力欄を空にします。 |
| `clearInput(sel, waitSeconds:scroll:maxSwipes:)` | 要素を指定して入力欄を空にします。 |

## 例

```swift
tap("#note")
clearInput()
type("new content")

clearInput("#note")
type("#note", "new content")

// clearInput + type を1コマンドに畳む
type("#note", "new content", replace: true)
```

## 注意点

- **ボタンなど入力欄でない要素を指すと、消す前に失敗します。** `clearInput` は消す前に対象をタップするので、
  そのまま撃つと送信・購入などのボタンを押してしまいます。UI フレームワークが UIKit・SwiftUI・React Native・
  Android View と分かっていて、要素の型がボタン・スイッチ・リンクなどのときだけ断ります(Compose・Flutter は
  本物の入力欄が別の型で報告されることがあるので断りません)。入力欄を1つだけ包む要素を指したときは、
  断らずに従来どおり実行します。
- **空白は検証できません。** 空白だけの内容はアクセシビリティの値に載らないため、消えたことをツールは検証できません。`type` の後で末尾・途中の空白が欠けても検出できないので、空白が意味を持つ値は `textIs` で確かめてください。

- `type` は追記なので、書き換えたいときはまずクリアします。セレクタ解決を1回で済ませたい
  だけなら `type(sel, "文字列", replace: true)` でクリアと入力を1コマンドに畳めます。
  詳細は [type](./type_ja.md) 参照。
- **Flutter の iOS ビルド**では in-app エンジンでは欄を消せず、この1コマンドだけ自動で
  XCUITest エンジンへフォールバックします(1〜2秒ほど余分にかかります)。

### Link
- [index](../../index_ja.md)
