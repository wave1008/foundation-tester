# 環境

[in English](environments.md)

## 対応環境

| 対象 | 要件 |
|---|---|
| 共通 | Apple silicon の Mac、macOS 26+(Intel Mac は対象外) |
| iOS をテストするなら | Xcode 26+、iOS Simulator、[xcodegen](https://github.com/yonaskolb/XcodeGen) |
| Android をテストするなら | Android SDK(adb)、Emulator または実機 |
| VSCode 拡張のインストール | VSCode、Node.js v24 以降、npm v11 以降(拡張をビルドして入れるため) |


## 動作確認している UI フレームワーク

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS、Android |
| Flutter | iOS、Android |
| React Native | iOS、Android |
| View/XML | Android |


## Foundation Models を使う機能(任意)

Apple silicon の Mac・macOS 27+ で Apple Intelligence を有効化すると Foundation Models(FM) を使う機能をテストで使用することができます。
有効化は、macOS 27 は システム設定 → Siri で Siri をオン(Siri が Apple Intelligence を使います)、macOS 26 は システム設定 → Apple Intelligence と Siri で「Apple Intelligence」をオンにします。

- **`screenLooksLike`**
  - 画面と自然文の説明を照合する視覚検証です。
- **テキストの視覚検証**
  - テキストが実際に表示されているか、別のものに覆われて隠れていないかを視覚的に判定し、テスト結果の判定精度を向上させることができます。

これらの機能の処理はすべてオンデバイスで、アプリの画面情報が Mac の外に出ることはありません(テストを作るときに AIアシスタントへ送られる画面の内容は別です)。
Apple のクラウドの Private Cloud Compute (PCC) は使いません。

### 制限

- **experimental(実験的機能) です。**
- macOS 26 では FM の機能は使えません。
- FM が使えない環境では、`screenLooksLike` は失敗ではなく**スキップ**されます。

次へ: [はじめに(インストール)](../getting-started_ja.md)

### Link
- [index](../index_ja.md)
