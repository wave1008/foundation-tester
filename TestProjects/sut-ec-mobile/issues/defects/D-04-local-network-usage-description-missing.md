# D-04 iOS: ローカルネットワーク権限ダイアログの説明文が「(null)」で出る

| 項目 | 内容 |
|---|---|
| 対象 | iOS アプリ全体 / Info.plist(`NSLocalNetworkUsageDescription`) |
| 対応 SC/TC | なし(観点「クロスプラットフォーム › iOS Info.plist制約」) |
| 重大度 | 中(初回起動の権限ダイアログに `(null)` が露出。App Store 審査では説明文必須) |
| 状態 | 起票 |
| 検出 | 手動(探索的テスト)/ iPhone 13・iOS 26.6.1・実機 |
| 起票日 | 2026-08-31 |

**再現手順**
1. 実機用ビルド(接続先を LAN の IP に焼いたもの)を初回インストールして起動する。
2. iOS が出す「"SUT Store" がローカルネットワーク上のデバイスを見つけることを許可しますか?」を読む。

**期待結果**: アプリがローカルネットワークへ接続する理由が日本語/英語で表示される。

**実際の挙動**: 説明文の位置に **`(null)`** と表示される。`dist/ios-device/SUTStore.app/Info.plist` に
`NSLocalNetworkUsageDescription` が無い(`NSAppTransportSecurity › NSAllowsLocalNetworking` だけがある)。

**証拠**: SpringBoard の ft_snapshot
`staticText "(null) ネットワークからの情報を使用して、あなたのプロファイルを作成するこ…"`。
`plutil -p Info.plist | grep UsageDescription` → 0 件。

**仕様裁定(要判断があれば)**: `iosApp/project.yml` の Info.plist 設定に
`NSLocalNetworkUsageDescription`(ja/en)を追加する。シミュレータでは出ないため実機でしか露見しない。
