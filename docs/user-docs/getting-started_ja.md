# はじめに(インストール)

Fleetest のインストール・更新・アンインストールの手順です。

## 1. 環境

対応する macOS・Xcode・Android SDK などの要件は [環境](overview/environments_ja.md) を参照してください。

## 2. 事前準備

- **iOS をテストする場合**
  - Xcode と iOS Simulator のランタイムをインストールしておく
- **Android をテストする場合**
  - Android Studio(Android SDK)をインストールしておく
- **AIアシスタント**
  - MCP に対応した AIアシスタント(Claude Code・Codex・Cline・Cursor・Copilot など)を
    インストールしておく。どの AIアシスタントでも、インストールは AIアシスタントに頼んで進めます。
    Claude Code の場合:

```bash
brew install claude-code
```

## 3. Fleetest のインストール

1. **テスト専用の新規フォルダ**を VSCode で開き、AIアシスタントを起動して次のように頼みます

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して、
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

   clone・ビルド・テストパッケージの用意が進みます(プロジェクトとプロファイルは[クイックスタート](quick-start_ja.md)で作ります)

2. VSCode で `Developer: Reload Window` を実行します

3. VSCode の左下のステータスバーに表示される **fleetest mobile** をクリックします(デバイスモニターが開きます)

> **Claude Code 以外の場合**: Claude Code では MCP サーバの登録(`.mcp.json`)もセットアップが書きます。
> それ以外の AIアシスタントでは、MCP サーバを AIアシスタントの設定に自分で登録します(fleetest は
> AIアシスタントのグローバル設定には書き込みません)。書き方は
> [その他のエージェント](reference/tools/other_agents_ja.md#2-mcp-サーバを登録する)を参照してください。
>
> **Codex を使う場合**: 手順1は `codex --sandbox danger-full-access` で起動したセッションで行ってください。
> 既定のサンドボックスでは `swift build` と Simulator の操作が塞がれます。セットアップ後の `ft_*` の作業は
> 既定のままで動きます(詳細は[その他のエージェント](reference/tools/other_agents_ja.md#codex-を使う場合サンドボックス))。

## 4. Fleetest の更新

更新があると、VSCode 拡張が起動時に通知します(1日1回まで。確認するだけで、勝手に取り込みは
しません)。通知が不要なら設定 `fleetest.updateCheck` を `off` にしてください。

### VSCode から更新する

デバイスモニターの「設定」タブで確認と実行ができます。更新があるとタブの隣に「更新する」
ボタンが現れ、押すとそのまま取り込みが始まります。完了したら**再読み込み**を押してください
(押さないと更新前の拡張が動き続けます)。詳細は [VSCode 拡張](reference/tools/vscode_extension_ja.md)。

### ターミナルから更新する

AIアシスタントに「fleetest を更新して」と頼む(Claude Code では `/fleetest-update`)か、
`bash <TOOL_ROOT>/Scripts/update.sh` の1コマンドで更新できます。pull・ビルド・拡張・
スキルの更新まで行い、更新が無ければ何もしません。全部やり直したいときは `--force` を
付けます。スキルが更新されたときは、AIアシスタントを起動し直してください。

> **クローン(`foundation-tester`)を自分で書き換えている場合**: 更新時、クローン側のローカル
> 変更は確認なしで破棄されます。テスト資産は作業フォルダ側にあり、クローンは配布物として扱う
> ためです。残したい変更は先にコミットするか、`--keep-local` を付けてください。
>
> 詳しいログは `<作業フォルダ>/.fleetest/install-*.log` に残ります。clone と初回ビルドには
> 数分かかりますが、各ステップの完了ごとに1行ずつ表示されるので、そのまま待って構いません。

## 5. Fleetest のアンインストール

### VSCode 拡張

VSCode の拡張ビューからアンインストールします。

### 作業フォルダ

VSCode を終了してから Finder や `rm` で削除します。

作業フォルダを残す場合は、`AGENTS.md` と `CLAUDE.md` の `<!-- fleetest:begin -->` 〜
`<!-- fleetest:end -->` の範囲を削除してください(`AGENTS.md` に本文、`CLAUDE.md` にはその読み込みだけがあります)。インストーラが置いたエージェント向けの案内で、範囲外には触れて
いません。他のエージェントに MCP サーバを自分で登録していた場合は、その設定も削除します。
あわせて、インストーラがコピーしたスキル(`.claude/skills/fleetest-*` と `.claude/skills/.fleetest-copied`)も削除してください。

### 残るファイルとプロセス

fleetest のプロセスを止めてから(下のコマンド)、次のものも削除します。

- fleetest のクローン(既定では作業フォルダの隣の `foundation-tester`。ビルドフォルダを含めて数 GB あります)
- `~/.fleetest`(この Mac での実行の記録など)と `~/Library/Logs/fleetest`(ログ)
- 必要なら `~/.config/fleetest/config.json`
- fleetest のために作った仮想デバイスが不要なら、Xcode の「Devices and Simulators」や Android Studio の
  Device Manager から削除します

作業フォルダを削除しても `.build` が復活する場合は、fleetest のプロセスが残っています。

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 6. トラブルシュート

問題が起きたら AIアシスタントに相談してください。よくある症状と切り分けは
[トラブルシューティング](in_action/troubleshooting_ja.md)にまとめてあります。

### Link
- [index](index_ja.md)
