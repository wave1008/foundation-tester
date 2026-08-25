# はじめに（インストール）

Ftester は iOS / Android アプリのテストツールです。

## 配布方針
macOS や Xcodeのベータ版を前提としているので現時点ではバイナリ配布はしません。Claude Codeのプラグインを使用し、リポジトリを clone してビルドすることでインストールします。

## 1. 必要環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+ |
| iOS | Xcode 26+、iOS シミュレータ runtime、xcodegen |
| Android（任意） | Android SDK（adb）、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 以降 / npm v11 以降(v24 と v26 で確認済み) |

一部の機能（視覚検証）は macOS 27+ で利用可能です

## 2. 事前準備

Ftesterのインストールをスムーズに行うため、事前に以下の作業を実施してください。

- Xcode
  - Xcode 本体をインストールします
  - テストで使用したい Simulator を作成して起動しておいてください
- Android Studio
  - Android Studio本体をインストールします
  - テストで使用したいAVDを作成して起動しておいてください
  - AVD を ftester 側（モニターの「デバイスを追加」）から作るには Android SDK Command-line Tools
    が要ります。未導入なら同じダイアログの「Command-line Tools を導入」ボタン（または
    `ftester api install-cmdline-tools`）から入れられるので、事前準備は不要です

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

更新があるかどうかは、VSCode 拡張が起動時（1日1回まで）に自動で確認して通知します。確認するだけで
取り込みは行いません。通知が不要なら設定 `ftester.updateCheck` を `off` にしてください。

**更新の状態は、デバイスモニターの「設定」タブ**で確認できます（「更新を確認」ボタン）。
更新が見つかると、そのまま更新するかをダイアログで聞かれます。
更新があるときは**タブの右隣に「更新する」ボタンが現れます**（どのタブを見ていても表示されます）。
押すとそのまま取り込みが始まります。進行はスピナーと画面右下の通知に出て、詳しいログは
VSCode の **OUTPUT（ftester）** に流れます。通知の「設定タブを開く」からも移動できます。
完了すると再読み込みを促すダイアログが出るので、**再読み込み**を押してください（押さないと更新前の拡張が動き続けます）。

コマンドパレットの **`ftester: 更新を確認`** でも確認できます（間隔や「この版は通知しない」に
関係なく毎回確認し、最新なら最新と答えます）。ターミナルなら
`bash <TOOL_ROOT>/Scripts/update-check.sh`（どちらも何も変更しません）。

取り込む手順:

1. ターミナルで以下を実行します

```bash
claude plugin marketplace update foundation-tester
claude plugin update ftester@foundation-tester
```

2. Claude Codeの新しいセッションを開始し、 `/ftester:ftester-update` を実行します

Claude Code を使わない場合は `bash <TOOL_ROOT>/Scripts/update.sh`(pull・ビルド・拡張・
プラグイン更新までを1コマンドで行います)。更新が無ければ何もせず終わります（前回が途中で
失敗した場合など、全部やり直したいときは `--force`）。

> **クローン（`foundation-tester`）を自分で書き換えている場合の注意**
> 更新時、クローン側のローカル変更は**確認なしで破棄されます**（テスト資産は作業フォルダ側に
> あり、クローンは配布物として扱うため）。残したい変更があるときは `--keep-local` を付けるか、
> 先にコミット・`git stash` してください。`.build/` などビルド成果物は消えません。
> `swift build` や npm の詳しいログは画面に出ませんが、`<作業フォルダ>/.ftester/install-*.log`
> に全文が残ります（場所は開始時と最後に表示されます。画面にも出したいときは `--verbose`）。
> 進行状況は各ステップが終わるたびに1行ずつ表示されるので、無反応に見えても待って構いません
> （クローンと初回ビルドは数分かかります）。


## 5. Ftesterのアンインストール

### プラグインのアンインストール

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall ftester@foundation-tester
```

### VSCode拡張のアンインストール

- VSCodeの拡張ビューからアンインストールします

### 作業フォルダの削除

- VSCodeを終了してから Finder や rm で削除します
- **作業フォルダを残す場合**は、`CLAUDE.md` の `<!-- ftester:begin -->` 〜 `<!-- ftester:end -->`
  の範囲も削除してください(インストーラが置いた Claude Code 向けの案内。範囲外には触れていません)

### ファイルの削除

- 必要ならば `~/.config/ftester/config.json` も削除します

### プロセスの削除
- 作業フォルダを削除しても `.build` が復活する場合は下記コマンドを実行してください

```bash
pgrep -fl 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
pkill  -f 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
```

## 6. トラブルシュート

- 問題が発生した場合、Claude Codeに相談してください

### Link
- [index](index_ja.md)
