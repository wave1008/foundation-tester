# はじめに(インストール)

[in English](getting-started.md)

fleetest のインストールの手順です。

## 1. 環境

対応する macOS・Xcode・Android SDK などの要件は [環境](overview/environments_ja.md) を参照してください。

## 2. 事前準備

- **iOS をテストする場合**
  - Xcode と iOS Simulator のランタイムをインストールしておく
- **Android をテストする場合**
  - Android Studio(Android SDK)をインストールしておく
- **VSCode と Node.js**
  - VSCode と、Node.js v24 以降(npm v11 以降)をインストールしておく(VSCode 拡張をビルドして入れるため)
- **AIアシスタント**
  - MCP に対応した AIアシスタント(Claude Code・Codex・Cline・Cursor・Copilot など)を
    インストールしておく。どの AIアシスタントでも、インストールは AIアシスタントに頼んで進めます。

## 3. fleetest のインストール

1. **テスト専用の新規フォルダ**を作成し、VSCode で開きます

2. AIアシスタントを起動して次のように指示します

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

3. インストールが完了したら、VSCode で `Developer: Reload Window` を実行します。AIアシスタント(Claude Code を含む)も
   一度終了し、このフォルダで新しいセッションを開きます。MCP サーバ `fleetest` の使用を確認されたら許可します
   (インストールで登録した `ft_*` ツールとスキルは、新しいセッションから使えます)

4. VSCode の左下のステータスバーに表示される **fleetest mobile** をクリックします。デバイスモニターが開きます

5. **Claude Code 以外の AIアシスタント**を使う場合は、「MCP を登録して」と頼みます。登録したら AIアシスタントを
   再起動し、このフォルダで新しいセッションを開きます(画面の探索やシナリオの実行に使う `ft_*` ツールが使えるようになります)。
   詳しくは [Claude Code 以外の AIアシスタント](reference/tools/other_agents_ja.md)の「MCP サーバを登録する」を参照してください

6. AIアシスタントに「fleetest doctor を実行して結果を報告して」と頼み、エラーが出ないことを確かめます

インストールすると、作業フォルダの隣に `foundation-tester` フォルダができます。このドキュメントで手で打つコマンドの
`../foundation-tester/.build/debug/fleetest` は、その中の `fleetest` を指します。

インストールが済んだら、[クイックスタート](quick-start_ja.md)でテストを作って実行してみましょう。

## 4. トラブルシュート

問題が起きたら AIアシスタントに相談してください。よくある症状と切り分けは
[トラブルシューティング](in_action/troubleshooting_ja.md)にまとめてあります。

次へ: [クイックスタート](quick-start_ja.md)

### Link
- [index](index_ja.md)
- [クイックスタート](quick-start_ja.md)
