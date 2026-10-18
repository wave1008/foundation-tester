# 環境

[in English](environments.md)

## 対応環境

### 利用者が用意してインストールするもの

| 対象 | 要件 |
|---|---|
| マシンと OS | Apple silicon の Mac、macOS 26+ |
| Xcode | Xcode 26+(<https://apps.apple.com/jp/app/xcode/id497799835>) |
| Homebrew | Homebrew(<https://brew.sh/ja/>) |
| VSCode | VSCode(<https://code.visualstudio.com/docs/setup/mac>) |
| Android SDK | Android SDK(adb・Command-line Tools)(<https://developer.android.com/studio/install?hl=ja>) |

### 自動でインストールされるもの

- xcodegen
- Node.js
- VSCode 拡張(fleetest mobile)
- iOS Simulator のランタイムと Simulator
- Android のシステムイメージと Emulator

## 動作確認している UI フレームワーク

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |


## Foundation Models を使う機能(macOS 27+)

macOS 27+ で Apple Intelligence を有効化すると Foundation Models(FM) を使う機能をテストで使用することができます。
有効化は、システム設定 → Siri で Siri をオンにします。

### 制限

- **experimental(実験的機能) です。**
- FM が使えない環境では、`screenLooksLike` は失敗ではなく**スキップ**されます。

次へ: [クイックスタート](../quick-start_ja.md)

### Link
- [index](../index_ja.md)
