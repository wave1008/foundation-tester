# トラブルシューティング

よくある問題と対処法です。

| 症状 | 確認 | 対処 |
|---|---|---|
| オンデバイスモデルが利用不可 | システム設定で Apple Intelligence が有効か | 有効化する(`fleetest doctor` が利用不可の理由を表示します)。`availability` が available のまま全呼び出しが失敗することがある(OS 更新の直後などに起きた)ので、実際に推論する `fleetest doctor --fm-only` で確認する。一度止まった FM は Mac を再起動するまで戻らないので、`--fm-only` が失敗し続けるなら Mac を再起動する([長く使うためのメンテナンス](maintenance_ja.md))。FM は experimental([environments_ja.md](../overview/environments_ja.md))。これがブロックするのは `screenLooksLike`・遮蔽チェック(`exist` の `requireVisible` 判定)だけで、自己修復(ロケータの指紋照合。FM を使いません)を含め他は無くても動きます |
| ドライバに接続できない | iOS: ブリッジが起動しているか。Android: `adb devices` にデバイスが見えているか | iOS: 先に `fleetest bridge up` を実行する(ログは `.fleetest/bridge-<ポート>.log`)。Android: デバイス/Emulator を繋ぎ直して `adb devices` に出るようにする |
| fleetest が起動直後に `dyld[…]: Symbol not found` / `Library not loaded` で落ちる | macOS を更新したのに Xcode が古いままではないか(`fleetest doctor` が起動できるなら、macOS と SDK の版を表示します) | Xcode を macOS と同じ世代にそろえ、fleetest のクローンと作業フォルダの `.build` を消して `bash <TOOL_ROOT>/Scripts/update.sh --force` を実行する([長く使うためのメンテナンス](maintenance_ja.md)) |
| コンパイルエラーでシナリオが実行できない | `swift build --product fleetest-scenarios-<プロジェクト名>` を実行してエラーを読む | 表示されたエラーを修正する。ライブ操作録画(gen-scenario)が生成したコードがコンパイルできない場合は、プロジェクト全体を止めず自動で `scenarios/_disabled/` に隔離されます |
| プロジェクトが認識されない(手動コピーや `git pull` の後) | `fleetest project list` が未登録のプロジェクトを警告していないか | `fleetest project sync` で `Package.swift` のマーカー区間を再生成する |
| 「デバイスが見つからない」/デバイスが黙ってスキップされる | 実行プロファイルの `devices` にそのデバイスが載っているか(`machine`/`name` は正しいか) | `fleetest profile list` で解決結果を確認するか、`fleetest profile setup --auto-device` で登録する |
| Android の snapshot が遅い | `fleetest bridge status --platform android` と `fleetest doctor` でブリッジの導入・起動状況を確認 | `fleetest bridge up --platform android` で常駐ブリッジを強制的に再セットアップする |
| Android で日本語(非 ASCII)入力が入らない | ブリッジは通常 `ACTION_SET_TEXT` で入力するため IME 切替は不要 | `fleetest doctor` でブリッジの導入状況を確認する。ブリッジの再導入(`fleetest bridge up --platform android`)で解消することが多い |

これで解決しない場合はエージェントに相談してください。ブリッジ・実行ログや失敗レポートを直接読んで調査できます。

### 不具合を報告するとき

保守者へ不具合を報告するときは `fleetest doctor --bundle fleetest-diag.zip` を実行し、できた zip を
添付してください。ブリッジ/install/cleanup/Emulator の各ログ・直近の run 結果
(`--runs`。既定3件。対象は `--project` または既定プロジェクト。シナリオごとの実行ログを含む)・
ツールと OS の版・`fleetest doctor --roots-only` / `--fm-only` の結果を1つのファイルにまとめます。
ブリッジを止めたり起動し直したりはせず、このコマンド自体はどこへも送信しません。
**zip にはアプリの画面の文字(ステップの説明・要素一覧)が含まれることがある**ので、共有する前に
中身を確認してください。

### Link
- [index](../index_ja.md)
