---
name: ftester-setup
description: foundation-tester を使いたい受け手を、自分の iOS/Android アプリ向けにシナリオを書いて実行できる状態まで初期セットアップする。未クローンなら clone から行い、ビルド・環境検証・自分のプロジェクト作成・マシン/アプリのプロファイル設定・VSCode 拡張のインストールを、検証ゲートと人間チェックポイント付きで順に実行する。「セットアップして」「使えるようにして」「動かせるようにして」等の初回導入依頼で使う。
---

# ftester 初期セットアップ runbook

受け手を、**自分のアプリのシナリオを書いて実行できる状態**まで導く。
全体像・背景は docs/getting-started.md。ここはエージェントが順に実行するための手順書。

**入り方は2通り。ステップ 0.5 で判定する:**

- **外部パッケージ構成(既定・curl でスキルだけ入れた受け手ディレクトリ)**: いま開いているこの
  ディレクトリを ftester テストパッケージにする。**あなたのプロジェクト(`Projects/<name>/`)は
  この受け手ディレクトリに作られる**。foundation-tester は「ツール(CLI・拡張)」として横に clone+build
  するだけで、Projects はここに住む。作成は `ftester init`。
- **clone 構成(foundation-tester クローンの中で直接作業する保守者/PoC)**: Projects はクローンの
  `Projects/` に作る。作成は `ftester project create`。

以降、**TOOL_ROOT** = foundation-tester クローン(swift build / doctor / 拡張ビルドを行う場所。CLI は
`TOOL_ROOT/.build/debug/ftester`)、**WORK_DIR** = `Projects/` が住む作業ディレクトリ、と呼ぶ。
外部構成では WORK_DIR = このカレント・TOOL_ROOT = `../foundation-tester`。clone 構成では両者は同一(クローン)。

## 進め方の原則

- **各ステップの後に検証ゲートを通す**（exit code / doctor / 到達確認）。緑になるまで次へ進まない。
- **人間チェックポイント（🧑）では必ず停止して依頼・確認する**。エージェントでは代行できない。
- **セットアップ値は探索せず人間に聞く**：Bundle ID・App ID・ビルド済み `.app`/`.apk` のパス・
  テスト対象アプリの所在などを、兄弟ディレクトリや別リポジトリを勝手に `find`/`grep` で探索して
  確定してはならない。必ず人間に質問して答えを得る（探索で見つけた候補を既定値として提示するのも避ける）。
  「質問を減らすため」の事前調査も禁止。
- **冪等に**：既に済んでいる状態を検出したらスキップする（再実行に強く）。
- 失敗したら握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

## 手順

### 0. 🧑 人間チェックポイント（前提）

先に次を人間に確認する。未達なら停止して依頼する（エージェントでは実施不可）:

- macOS 27+ か
- Xcode 27+ 導入済み・`sudo xcodebuild -license accept` 済みか
- （初回のみ）テスト対象アプリのビルド済み `.app` / `.apk` のパス、マシン名
  → **人間に聞く。他リポジトリを勝手に探索して埋めない**（バージョン・パスの推測は事故のもと）。

（シミュレータは step 5 で自動採取・自動選択するのでここでは聞かない。）

### 0.5 入り方の判定と TOOL_ROOT の取得

カレントか祖先に `Package.swift` と `Sources/FTScenarioRunner/` の**両方**があるかで判定する
(この2つが揃うのは foundation-tester クローンだけ):

- **両方ある = clone 構成**: いま foundation-tester クローンの中にいる。TOOL_ROOT = WORK_DIR =
  そのディレクトリ。取得不要でステップ1へ。
- **無い = 外部パッケージ構成(既定)**: WORK_DIR = このカレント(ここに Projects/ を作る)。
  ツールを供給するため foundation-tester を**兄弟ディレクトリ**に clone+build する(受け手の
  ディレクトリの中にネストさせない):

```
git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester
```

  → TOOL_ROOT = `../foundation-tester`。build / doctor / 拡張ビルドは TOOL_ROOT で、`ftester init` と
  プロファイル設定は WORK_DIR(カレント)で行う。**カレントに `Package.swift` があってはいけない**
  (`ftester init` が拒否する。既存 repo の直下ではなく、テスト専用の新規ディレクトリで実行する)。

版を固定したい場合は 🧑 に確認して TOOL_ROOT で `git checkout <tag>`(配布はソースビルド前提なので
tag も clone で取得できる)。

### 1. xcodegen

`command -v xcodegen` で確認。無ければ `brew install xcodegen`（未導入だと iOS ブリッジ生成が失敗する）。

### 2. ビルド

**TOOL_ROOT で** `swift build`（初回は数分）。**exit code で成否を判定**（パイプで grep に繋がない）。
これで `TOOL_ROOT/.build/debug/ftester`(CLI 本体)が揃う。以降 `ftester` はこのバイナリを指す。

### 2.5 Apple Intelligence 自動判定ゲート（人間に聞かない）

**TOOL_ROOT で** `swift run ftester doctor --fm-only` を実行する。これは `SystemLanguageModel.default.availability`
（オンデバイス FM／Apple Intelligence の可否）だけを見て **exit code で返す**（可=0／不可=1）。
オンデバイス FM はこのツールの頭脳なので、ここが緑でないと以降は無意味。**人間に「有効か」を聞かない**：

- **exit 0**（`✅ 利用可能`）→ 次へ。
- **exit 1 で `Apple Intelligence が無効`** → 🧑 停止して依頼する：System 設定 → Apple Intelligence & Siri
  でオンにしてもらう。有効化後に本コマンドを再実行（ビルドはキャッシュ済みで即座）。
- **exit 1 で `モデルのダウンロード中`** → 数分待って再実行（DL 完了で 0 になる）。
- **exit 1 で `このデバイスは対象外`** → このマシンではオンデバイス FM を使えない。🧑 に伝えて相談。

### 3. 環境検証ゲート

**TOOL_ROOT で** `swift run ftester doctor` を実行し、出力をユーザーに要約して見せる（FM/AI は 2.5 で判定済み）。
赤（未導入・無効）が残る項目は、ステップ0に戻って人間に対処を依頼してから再実行。全緑で次へ。

### 4. 自分のプロジェクトを作る(構成で分岐)

プロジェクト名（英数字 `^[A-Za-z0-9_][A-Za-z0-9_-]*$`）とアプリの bundle ID を🧑に確認して、
**WORK_DIR(カレント)で**作る:

- **外部パッケージ構成(既定)**: `ftester init` で WORK_DIR を ftester テストパッケージにする。
  TOOL_ROOT を SPM のローカルパス依存として引き、最初のプロジェクトを登録する:

```
../foundation-tester/.build/debug/ftester init \
  --ftester-path ../foundation-tester --name <ProjectName> --app <bundleID>
```

  → WORK_DIR に `Package.swift`(空マーカー区間 + ftester 依存)と `Projects/<ProjectName>/` が生成され、
  受け手専用の `/ftester-setup` スキルが `.claude/skills/` に上書きされる(次回以降の実行はそちらを使う。
  この実行はロード済み手順のまま継続してよい)。ローカルパス依存なので `swift build` はネットワーク不要・
  TOOL_ROOT を `git pull` すれば ftester 側も更新される。git 依存にしたい場合のみ `--ftester-url
  https://github.com/wave1008/foundation-tester.git --ftester-version <ver>` を使う(`--ftester-path` と排他)。
  以降このスキル内で `ftester ...` と書いたら `../foundation-tester/.build/debug/ftester ...` を実行する。

- **clone 構成**: TOOL_ROOT(=WORK_DIR)で `swift run ftester project create <ProjectName> --app <bundleID>`。
  `Projects/<ProjectName>/` と Package.swift のターゲット登録が生成されたことを確認する。

### 5. マシンプロファイル（このPC）

以降のプロファイル編集は **WORK_DIR の `Projects/<ProjectName>/`** に対して行う。

- `ftester machine set "<マシン名>"` を実行（machines/ が1つだけなら自動採用が効くので省略可。
  複数マシンを1クローンで扱う時のみ必須。登録先は `~/.config/ftester/config.json` でグローバル）。
- `xcrun simctl list devices available` で使えるシミュレータを採取し、**シミュレータはユーザーに聞かず
  自動選択**する（既定：利用可能な中で最新 iOS の iPhone。Pro があれば優先、無ければ先頭の iPhone）。
  `Projects/<ProjectName>/profiles/machines/<マシン名>.json` を自動作成し、選んだ名前を要約報告する
  （後から編集可。雛形は同ディレクトリの README.md）。`name` は runs から参照されるため ios/android
  横断で一意に:

```json
{ "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] } }
```

- 利用可能な iOS シミュレータが **0 件のときだけ** 🧑 停止し、Xcode で runtime/デバイスの導入を依頼する。

### 6. アプリのパスを向ける

`Projects/<ProjectName>/profiles/apps/<projectname>.json` を編集し、🧑 に確認したビルド済みアプリへ
`appPath` を向ける（ios は `.app`、android は `.apk`）。相対パスは **WORK_DIR(そのプロジェクトの
Package.swift があるディレクトリ)基準**・`~` 展開可・絶対パス可。
**bundle ID と appPath は人間に確認した値を書く。別リポジトリを覗いて確定値を書き込まない。**

### 7. VSCode 拡張のインストール

**TOOL_ROOT の拡張を**ビルド・インストールする（外部構成でも拡張は TOOL_ROOT 側から入れる）:

```
cd ../foundation-tester/vscode-ftester && npm install && npm run install-local
```

（clone 構成なら `cd vscode-ftester && ...`。）`install-local` はパッケージ→インストール→到達確認まで
一括で行う。**exit code で成否判定**。

### 8. 🧑 人間チェックポイント（反映と起動）

ユーザーに依頼する（エージェントでは代行不可）:

- VSCode で **WORK_DIR** を開く（外部構成: あなたのテストパッケージのフォルダ。clone 構成:
  `foundation-tester` フォルダ）
- **外部パッケージ構成のときは** 設定 `ftester.binaryPath` を TOOL_ROOT の CLI に向ける
  （ワークスペース相対で `../foundation-tester/.build/debug/ftester`、または絶対パス。拡張は設定値が
  実在すればそれを、無ければ PATH の `ftester` を使う）。clone 構成では既定 `.build/debug/ftester` のままでよい
- `Developer: Reload Window` を実行（インストール・設定だけでは反映されない）
- プロジェクトが複数あるなら設定 `ftester.project` を `<ProjectName>` にするか、拡張の選択で選ぶ
- ftester パネル（Test Explorer / デバイスモニター等）を開く

### 9. 続けてプロファイル一括作成へ（/ftester-profiles）

初期セットアップ（1〜8）が完了したら、**続けて `/ftester-profiles` スキルを呼び出す**
（マシン/アプリ/実行プロファイルの一括作成）。`/ftester-profiles` が完了したら、**そこで処理を終了する**。
指示にない追加作業を自分の判断で始めない（コミット・push・別プロファイルやシナリオの追加作成・
最適化提案などをこちらから勝手に行わない）。

## 完了後

外部パッケージ構成では、以後の `/ftester-setup`(デバイス定義・アプリパス・動作確認)は `ftester init` が
WORK_DIR に置いた**受け手専用スキル**が担う。更新（新しい修正版が出たとき）は `/ftester-update` を使う
（TOOL_ROOT で git pull → swift build 再ビルド → 依存版を揃える → 拡張再インストール → Reload Window）。
手動手順は docs/getting-started.md「更新のしかた」。
