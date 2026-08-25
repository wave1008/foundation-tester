# トラブルシューティング

よくある問題と対処法です。

| 症状 | 確認 | 対処 |
|---|---|---|
| オンデバイスモデルが利用不可 | システム設定で Apple Intelligence が有効か。**Mac のシステム言語が英語か** | 有効化する(`fleetest doctor` が利用不可の理由を表示します)。`ja-JP` だとペイン自体が現れず、`availability` は available のまま全呼び出しが失敗するので、実際に推論する `fleetest doctor --fm-only` で確認する。FM は experimental で 2026 年内は英語のみ([environments_ja.md](../overview/environments_ja.md))。これがブロックするのは自己修復・`screenLooksLike`・失敗トリアージだけで、他は無くても動きます |
| ドライバに接続できない | iOS: ブリッジが起動しているか。Android: `adb devices` にデバイスが見えているか | iOS: 先に `fleetest bridge up` を実行する(ログは `.fleetest/bridge-<ポート>.log`)。Android: デバイス/エミュレータを繋ぎ直して `adb devices` に出るようにする |
| コンパイルエラーでシナリオが実行できない | `swift build --product fleetest-scenarios-<プロジェクト名>` を実行してエラーを読む | 表示されたエラーを修正する。ライブ操作録画(gen-scenario)が生成したコードがコンパイルできない場合は、プロジェクト全体を止めず自動で `scenarios/_disabled/` に隔離されます |
| プロジェクトが認識されない(手動コピーや `git pull` の後) | `fleetest project list` が未登録のプロジェクトを警告していないか | `fleetest project sync` で `Package.swift` のマーカー区間を再生成する |
| 「マシンプロファイルが見つからない」 | 実行プロファイルの `"machine"` が `profiles/machines/` 配下のファイル名と一致しているか | `profiles/machines/<名前>.json` と正確に一致するよう名前を直す |
| Android の snapshot が遅い | `fleetest bridge status --platform android` と `fleetest doctor` でブリッジの導入・起動状況を確認 | `fleetest bridge up --platform android` で常駐ブリッジを強制的に再セットアップする |
| Android で日本語(非 ASCII)入力が入らない | ブリッジは通常 `ACTION_SET_TEXT` で入力するため IME 切替は不要 | `fleetest doctor` でブリッジの導入状況を確認する。ブリッジの再導入(`fleetest bridge up --platform android`)で解消することが多い |

これで解決しない場合は Claude Code に相談してください。ブリッジ・実行ログや失敗レポートを直接読んで調査できます。

### Link
- [index](../index_ja.md)
