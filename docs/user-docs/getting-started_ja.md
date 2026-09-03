# はじめに(インストール)

Fleetest のインストール・更新・アンインストールの手順です。

現時点ではバイナリ配布はしていません。ベータ版の macOS / Xcode を前提としているためで、
Claude Code のプラグインからリポジトリを clone してビルドする形でインストールします。
clone からビルドまではエージェントが進めるので、手で行う作業はわずかです。

## 1. 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+ |
| iOS をテストするなら | Xcode 26+、iOS シミュレータ、xcodegen |
| Android をテストするなら | Android SDK(adb)、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 以降、npm v11 以降 |

自己修復や視覚検証といった Foundation Models の機能を使うには、**Mac のシステム言語を英語に
する必要があります**(現時点では英語のみ対応)。視覚検証は macOS 27+ が必要です。詳細は
[必要環境](overview/environments_ja.md)。

## 2. 事前準備

インストールをスムーズに進めるため、テストに使うデバイスを先に用意しておいてください。

- **iOS をテストするなら**: Xcode をインストールし、使いたいシミュレータを作成して起動しておく
- **Android をテストするなら**: Android Studio をインストールし、使いたい AVD を作成して起動しておく。
  システムイメージは Play Store ではなく **Google APIs** を選ぶ —— Play Store イメージは `user`
  ビルドで、アプリの release ビルドはその上で WebView の中身を出せない(詳細は
  [selector/webview_ja.md](selector/webview_ja.md))

## 3. Fleetest のインストール

1. `claude` CLI が無ければインストールします

```bash
brew install claude-code
```

2. fleetest のプラグインを入れます

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin marketplace update foundation-tester
claude plugin install fleetest@foundation-tester --scope user
```

> 2行目の `marketplace update` は、マーケットプレイスを追加済みのマシンでキャッシュを更新する
> ためのものです。古いままだと `Plugin "fleetest" not found in marketplace` で失敗します。
> 新規導入なら何も起きません。

> **改名前の `ftester@foundation-tester` が入っている場合は、先に消してください。** 古い
> `/ftester:*` スキルが、もう存在しないコマンドを指したまま残ります。マーケットプレイス名は
> 変わっていないので、追加し直す必要はありません。
>
> ```bash
> claude plugin uninstall ftester@foundation-tester
> ```

3. **テスト専用の新規フォルダ**を VSCode で開きます

4. エージェントのパネルで `/fleetest:fleetest-setup` を実行します。clone・ビルド・プロジェクト
   作成・プロファイル設定が進みます

5. VSCode で `Developer: Reload Window` を実行します

6. VSCode の左下に表示される**デバイスモニター**をクリックします

手動で1つずつ確認しながら進めたい場合は `.claude/skills/fleetest-setup/SKILL.md` を参照して
ください。

Claude Code 以外のエージェント(Codex・Cline など)を使う場合は
[その他のエージェント](tools/other_agents_ja.md)を参照してください。手順書はツール中立なので
そのまま使えますが、インストーラの実行と MCP サーバの登録は自分で行います。

## 4. Fleetest の更新

更新があると、VSCode 拡張が起動時に通知します(1日1回まで。確認するだけで、勝手に取り込みは
しません)。通知が不要なら設定 `fleetest.updateCheck` を `off` にしてください。

### VSCode から更新する

デバイスモニターの「設定」タブで確認と実行ができます。更新があるとタブの隣に「更新する」
ボタンが現れ、押すとそのまま取り込みが始まります。完了したら**再読み込み**を押してください
(押さないと更新前の拡張が動き続けます)。詳細は [VSCode 拡張](tools/vscode_extension_ja.md)。

### ターミナルから更新する

```bash
claude plugin marketplace update foundation-tester
claude plugin update fleetest@foundation-tester
```

その後、エージェントの新しいセッションで `/fleetest:fleetest-update` を実行します。

`bash <TOOL_ROOT>/Scripts/update.sh` の1コマンドでも同じことができます。pull・ビルド・拡張・
プラグイン更新まで行い、更新が無ければ何もしません。全部やり直したいときは `--force` を
付けます。

> **クローン(`foundation-tester`)を自分で書き換えている場合**: 更新時、クローン側のローカル
> 変更は確認なしで破棄されます。テスト資産は作業フォルダ側にあり、クローンは配布物として扱う
> ためです。残したい変更は先にコミットするか、`--keep-local` を付けてください。
>
> 詳しいログは `<作業フォルダ>/.fleetest/install-*.log` に残ります。clone と初回ビルドには
> 数分かかりますが、各ステップの完了ごとに1行ずつ表示されるので、そのまま待って構いません。

## 5. Fleetest のアンインストール

### プラグイン

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall fleetest@foundation-tester
```

改名前の `ftester@foundation-tester` が残っていれば、同じように uninstall します。

### VSCode 拡張

VSCode の拡張ビューからアンインストールします。

### 作業フォルダ

VSCode を終了してから Finder や `rm` で削除します。

作業フォルダを残す場合は、`CLAUDE.md` の `<!-- fleetest:begin -->` 〜 `<!-- fleetest:end -->` の
範囲を削除してください。インストーラが置いたエージェント向けの案内で、範囲外には触れて
いません。他のエージェントに MCP サーバを自分で登録していた場合は、その設定も削除します。

### 残るファイルとプロセス

必要なら `~/.config/fleetest/config.json` も削除します。

作業フォルダを削除しても `.build` が復活する場合は、fleetest のプロセスが残っています。

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 6. トラブルシュート

問題が起きたら Claude Code に相談してください。よくある症状と切り分けは
[トラブルシューティング](in_action/troubleshooting_ja.md)にまとめてあります。

### Link
- [index](index_ja.md)
