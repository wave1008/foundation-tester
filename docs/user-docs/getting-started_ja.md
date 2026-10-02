# はじめに(インストール)

Fleetest のインストールの手順です。

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

## 3. Fleetest のインストール

1. **テスト専用の新規フォルダ**を VSCode で開き、AIアシスタントを起動して次のように頼みます

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して、
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

2. インストールが完了したら、VSCode で `Developer: Reload Window` を実行します

3. VSCode の左下のステータスバーに表示される **fleetest mobile** をクリックします(デバイスモニターが開きます)

## 4. トラブルシュート

問題が起きたら AIアシスタントに相談してください。よくある症状と切り分けは
[トラブルシューティング](in_action/troubleshooting_ja.md)にまとめてあります。

### Link
- [index](index_ja.md)
