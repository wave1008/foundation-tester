# 環境

[in English](environments.md)

## 対応環境

| 対象 | 要件 |
|---|---|
| 共通 | Apple silicon の Mac、macOS 26+(Intel Mac は対象外) |
| iOS をテストするなら | Xcode 26+、iOS Simulator、[xcodegen](https://github.com/yonaskolb/XcodeGen) |
| Android をテストするなら | Android SDK(adb)、Emulator または実機 |
| アプリがサーバー・DB・スタブを必要とするなら | Apple Container(macOS の `container` コマンド。Docker も可) |
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
- **テキストの可視性検証**
  - テキストが実際に表示されているか、別のものに覆われて隠れていないかを視覚的に判定し、テスト結果の判定精度を向上させることができます。

これらの機能の処理はすべてオンデバイスで、アプリの画面情報が Mac の外に出ることはありません(テストを作るときに AIアシスタントへ送られる画面の内容は別です)。
Apple のクラウドの Private Cloud Compute (PCC) は使いません。

FM の画像推論では、一部の中断に対し、元の20秒の期限に十分な残り時間があれば1回だけ再試行します。
結果JSONの `fm.retries` に追加試行数、`fm.retrySuccesses` に追加試行で回答を得た数が残ります。
拒否と死活確認は再試行しません。

対象ホストとrunを揃え、`fm.retrySuccesses` の合計を `fm.retries` の合計で割り、100を掛けると再試行の回復率になります。
再試行0件なら未測定です。再試行しなかった要求と、サーバー応答を受信できなかった試行は対象に含みません。
FMが有効な回答を返せた割合を表し、`screenLooksLike` が不一致と答えた回も含みます。テストの合格率やANEのアドレス空間の回復率は表しません。

### 制限

- **experimental(実験的機能) です。**
- macOS 26 では FM の機能は使えません。
- FM が使えない環境では、`screenLooksLike` は失敗ではなく**スキップ**されます。

次へ: [クイックスタート](../quick-start_ja.md)

### Link
- [index](../index_ja.md)
