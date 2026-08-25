# 必要環境

## 対応環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+。Apple Intelligence(Foundation Models)は**任意** —— heal・FM 視覚検証・シナリオ生成に使います。後から有効化すればそのまま使えます |
| iOS | Xcode 26+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android(任意) | Android SDK(adb)、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 以降、npm v11 以降(v24 と v26 で確認済み) |

> macOS 26 では FM の**視覚検証だけ**が使えません(画像入力 API が macOS 27+ 必須)。
> occlusion-guard(偽陽性チェック)と `screenLooksLike` は自動で無効になり、他は制限なく動きます。

このマシンで何が使えるかは `fleetest doctor`(または MCP の `ft_doctor`)でいつでも確認できます
—— Foundation Models の可用性・Xcode・xcodegen・シミュレータ・adb をまとめて確認します。

## Apple Intelligence の用途

Apple Intelligence(オンデバイスモデル)は任意ですが、有効にすると次の3つが使えるようになります。

- **自己修復(self-healing)**: セレクタが壊れたときにモデルが修復し、シナリオを続行させます
  (修復結果はキャッシュされるため、2回目以降の再実行ではモデルを呼びません)。
- **`screenLooksLike`**: 画面と自然文の説明を照合するマルチモーダルな視覚検証です。
- **失敗時のトリアージ**: シナリオが失敗したとき、モデルが原因の要約と修正提案をレポートに残します。

これらの処理は Mac の外に出ません —— Foundation Models はすべてオンデバイスで動作します。

## 動作確認している UI フレームワーク

Fleetest は次のフレームワークで作られたアプリで動作確認しています。

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS、Android |
| Flutter | iOS、Android |
| React Native | iOS、Android |
| View/XML | Android |

### Link
- [index](../index_ja.md)
