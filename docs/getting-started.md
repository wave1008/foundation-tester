# はじめに（インストール）

Ftesterは iOS / Android アプリのテスツールです。

## 配布方針
macOS や Xcodeのベータ版を前提としているので現時点ではバイナリ配布はしません。Claude Codeのプラグインを使用し、リポジトリを clone してビルドすることでインストールします。

## 1. 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+ |
| iOS | Xcode 26+、iOS シミュレータ runtime、xcodegen |
| Android（任意） | Android SDK（adb）、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 系 / npm v11 系 |

一部の機能（視覚検証）は macOS 27+ で利用可能です

## 2. 事前準備

Ftesterのインストールをスムーズに行うため、事前に以下の作業を実施してください。

- XCode
  - Xcode本体をインストールします
  - テストで使用したいSimlatorを作成して起動しておいてください
- Android Studio
  - Android Studio本体をインストールします
  - テストで使用したいAVDを作成して起動しておいてください

## 3. Ftesterのインストール

1. `claude` CLI をインストールしていなければインストールします

```bash
brew install claude-code
```

2. ftesterのプラグインを入れます

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin install ftester@foundation-tester --scope user
```

3. **テスト専用の新規フォルダ**を VSCode で開きます

4. Claude Code パネルで `/ftester:ftester-setup`を実行します
clone、ビルド、プロジェクト作成、プロファイル設定が実行されます

5. VSCode で `Developer: Reload Window` を実行します

6. VSCodeの左下に表示される　**デバイスモニター**　をクリックします


手動で1つずつ確認しながら進めたい場合は `.claude/skills/ftester-setup/SKILL.md` を参照してください。


## 4. Ftesterの更新

1. ターミナルで以下を実行します

```bash
claude plugin marketplace update foundation-tester
claude plugin update ftester@foundation-tester
```

2. Claude Codeの新しいセッションを開始し、 `/ftester-update` を実行します


## 4. Ftesterのアンインストール

### プラグインのアンインストール

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall ftester@foundation-tester
```

### VSCode拡張のアンインストール

- VSCodeの拡張ビューからアンインストールします

### 作業フォルダの削除

- VSCodeを終了してから Finder や rm で削除します

### ファイルの削除

- 必要ならば `~/.config/ftester/config.json` も削除します

### プロセスの削除
- 作業フォルダを削除しても `.build` が復活する場合は下記コマンドを実行してください

```bash
pgrep -fl 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
pkill  -f 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
```

## 7. トラブルシュート

- 問題が発生した場合、Claude Codeに相談してください
