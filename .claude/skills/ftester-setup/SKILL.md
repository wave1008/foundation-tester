---
name: ftester-setup
description: foundation-tester を使いたい受け手を、自分の iOS/Android アプリ向けにシナリオを書いて実行できる状態まで初期セットアップする。未クローンなら clone から行い、ビルド・環境検証・自分のプロジェクト作成・マシン/アプリのプロファイル設定・VSCode 拡張のインストールを、検証ゲートと人間チェックポイント付きで順に実行する。「セットアップして」「使えるようにして」「動かせるようにして」等の初回導入依頼で使う。
---

# ftester 初期セットアップ runbook

受け手を、**自分のアプリのシナリオを書いて実行できる状態**まで導く。
全体像・背景は docs/getting-started.md。ここはエージェントが順に実行するための手順書。
入り方は2通り(既にクローン内 / curl でスキルだけ入れた空ディレクトリ)。ステップ 0.5 で判定・取得する。

## 進め方の原則

- **各ステップの後に検証ゲートを通す**（exit code / doctor / 到達確認）。緑になるまで次へ進まない。
- **人間チェックポイント（🧑）では必ず停止して依頼・確認する**。エージェントでは代行できない。
- **冪等に**：既に済んでいる状態を検出したらスキップする（再実行に強く）。
- 失敗したら握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

## 手順

### 0. 🧑 人間チェックポイント（前提）

先に次を人間に確認する。未達なら停止して依頼する（エージェントでは実施不可）:

- macOS 27+ か
- Apple Intelligence が有効か（System 設定 → Apple Intelligence & Siri。オンデバイス FM に必須）
- Xcode 27+ 導入済み・`sudo xcodebuild -license accept` 済みか
- iOS シミュレータの runtime を1つ以上導入済みか
- （初回のみ）テスト対象アプリのビルド済み `.app` / `.apk` のパス、使いたいシミュレータ名、マシン名

### 0.5 リポジトリ取得（未クローンなら）

入り方を判定してからリポジトリルートを確定する:

- **既にクローン内**（カレントか祖先に `Package.swift` と `Sources/FTScenarioRunner/` の両方がある）
  → clone 済み。そのディレクトリをリポジトリルートとして以降を進める。
- **未クローン**（curl でスキルだけ入れた空ディレクトリ）→ ここで取得する。🧑 に clone 先を確認してよい
  （既定はカレント直下 `foundation-tester/`）:

```
git clone https://github.com/wave1008/foundation-tester.git
cd foundation-tester
```

以降のステップ（build / doctor / project create / install-local 等）は**このリポジトリルート内**で実行する。
版を固定したい場合は 🧑 に確認して `git checkout <tag>`（配布はソースビルド前提なので tag も clone で取得できる）。

### 1. xcodegen

`command -v xcodegen` で確認。無ければ `brew install xcodegen`（未導入だと iOS ブリッジ生成が失敗する）。

### 2. ビルド

リポジトリルートで `swift build`（初回は数分）。**exit code で成否を判定**（パイプで grep に繋がない）。

### 3. 環境検証ゲート

`swift run ftester doctor` を実行し、出力をユーザーに要約して見せる。
赤（未導入・無効）が残る項目は、ステップ0に戻って人間に対処を依頼してから再実行。全緑で次へ。

### 4. 自分のプロジェクトを作る

プロジェクト名（英数字 `^[A-Za-z0-9_][A-Za-z0-9_-]*$`）とアプリの bundle ID を🧑に確認して:

```
swift run ftester project create <ProjectName> --app <bundleID>
```

`Projects/<ProjectName>/` と Package.swift のターゲット登録が生成されたことを確認する。

### 5. マシンプロファイル（このPC）

- `swift run ftester machine set "<マシン名>"` を実行（machines/ が1つだけなら自動採用が効くので省略可。
  複数マシンを1クローンで扱う時のみ必須）。
- `xcrun simctl list devices available` で使えるシミュレータ名を採取。
- 🧑 使うデバイスを確認し、`Projects/<ProjectName>/profiles/machines/<マシン名>.json` を作成/編集する
  （雛形は同ディレクトリの README.md）。`name` は runs から参照されるため ios/android 横断で一意に:

```json
{ "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] } }
```

### 6. アプリのパスを向ける

`Projects/<ProjectName>/profiles/apps/<projectname>.json` を編集し、🧑 に確認したビルド済みアプリへ
`appPath` を向ける（ios は `.app`、android は `.apk`。`~` 展開可）。

### 7. VSCode 拡張のインストール

```
cd vscode-ftester && npm install && npm run install-local
```

`install-local` はパッケージ→インストール→到達確認まで一括で行う。**exit code で成否判定**。

### 8. 🧑 人間チェックポイント（反映と起動）

ユーザーに依頼する（エージェントでは代行不可）:

- VSCode でこの `foundation-tester` フォルダを開く
- `Developer: Reload Window` を実行（インストールだけでは反映されない）
- プロジェクトが複数あるなら設定 `ftester.project` を `<ProjectName>` にするか、拡張の選択で選ぶ
- ftester パネル（Test Explorer / デバイスモニター等）を開く

### 9. 動作確認

最小の1本を通す。CLI なら:

```
swift run ftester run --project <ProjectName> --profile ios
```

または拡張のライブ操作パネルで操作を録画してシナリオを1本生成して実行。ここまで通れば初期セットアップ完了。

## 完了後

更新（新しい修正版が出たとき）は `/ftester-update` を使う（git pull → project sync →
swift build → 拡張再インストール → Reload Window）。手動手順は docs/getting-started.md「更新のしかた」。
