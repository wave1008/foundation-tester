# 必要環境

## 対応環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+ |
| iOS をテストするなら | Xcode 26+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android をテストするなら | Android SDK(adb)、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 以降、npm v11 以降 |

iOS と Android を両方揃える必要はありません。テストする側だけ用意すれば動きます。

このマシンで何が使えるかは `fleetest doctor` がまとめて確認します —— Foundation Models・
Xcode・xcodegen・シミュレータ・adb。

## Apple Intelligence(任意)

Apple Intelligence(Foundation Models)は無くても動きますが、有効にすると次の2つが使えます。
後から有効化しても、そのまま使えるようになります。

- **`screenLooksLike`** —— 画面と自然文の説明を照合する視覚検証です。
- **遮蔽チェック(occlusion-guard)** —— `exist` の `requireVisible` 判定で、木には在るが
  別のものに覆われている要素を「見えている」と誤って緑にしないための確認です。

(自己修復は FM を使いません —— [自己修復](../running/self_healing_ja.md)参照 —— そのため
Apple Intelligence の有無に関わらず同じように動きます。)

処理はすべてオンデバイスで、アプリの画面情報が Mac の外に出ることはありません。
**Apple のクラウド(Private Cloud Compute)は使いません。** Foundation Models にはクラウド側で
動くモデルもありますが、fleetest はオンデバイスモデルだけを呼ぶよう固定してあり、クラウドへ
切り替える設定は用意していません。

### 制限

- **experimental です。** オンデバイスモデルは Apple Intelligence の対応言語(日本語を含む)で
  動き、Mac のシステム言語は日本語のままで使えます(macOS 27.0 で確認)。日本語 UI のアプリや
  日本語で書いた `screenLooksLike` の説明文に対する判定精度は、まだ計測していません。
- macOS 26 では `screenLooksLike` が使えません。画像入力が macOS 27+ 必須のためで、自動で
  無効になり、他の機能は制限なく動きます。テキストの視覚検証は FM の段を除いて動きます(下記)。
- FM が使えない環境では、`screenLooksLike` は失敗ではなく**スキップ**されます。テキストの視覚検証は
  FM の代わりに端末の OCR(`ocrTextOcclusionCheck`)の読みで判定し、「見えていない」と読めたら失敗にします
  (失敗文言に `judged by OCR alone` と出ます)。OCR で判定できない要素(何も読めないが何かが描かれている等)は
  確かめずに通るので、FM が実際に使えているかは `fleetest doctor --fm-only` で確認して
  ください。テキストと画像の2経路をそれぞれ実際に推論して判定し、どちらかが死んでいれば
  exit 1 になります。詳細は
  [トラブルシューティング](../in_action/troubleshooting_ja.md)。

## 動作確認している UI フレームワーク

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS、Android |
| Flutter | iOS、Android |
| React Native | iOS、Android |
| View/XML | Android |

### Link
- [index](../index_ja.md)
