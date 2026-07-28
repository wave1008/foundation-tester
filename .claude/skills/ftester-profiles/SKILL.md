---
name: ftester-profiles
description: ftester のマシンプロファイル・アプリプロファイル・実行プロファイルを1回のフローでまとめて作成する。最初に iOS/Android を確認し、アプリの表示名・アプリIDを聞き(パッケージパスは聞かない)、デバイスは指定があればそれで、無ければそのマシンで利用可能な最新OSの仮想デバイス(無ければ作成)で用意する。「プロファイルを作って」「デバイスとアプリと実行プロファイルをまとめて用意して」「テスト対象を追加して」等の依頼で使う。
---

# ftester プロファイル一括作成 runbook

> **この手順書が古い可能性がある**: プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` のスナップショットから読まれており `git pull` では更新されない。
> **clone(TOOL_ROOT)が既にあるなら `<TOOL_ROOT>/.claude/skills/ftester-profiles/SKILL.md` を読み、
> 内容が違えばそちらを正とする**。更新は `claude plugin marketplace update foundation-tester` →
> `claude plugin update ftester@foundation-tester`(2つとも要る・Claude Code の再起動で反映)。
> **`/plugin` スラッシュコマンドは VSCode 拡張・Agent SDK 環境では提供されない**ので CLI 形を使う。

1つのアプリ×1プラットフォーム分の **マシン/アプリ/実行プロファイルの三点セット** を作る。
既存プロジェクト(`ftester project create` / `ftester init` 済み)に対して実行する。未セットアップなら
`/ftester-setup` を案内する。

## 前提の確定(最初に1回)

- **プロジェクトと WORK_DIR**: プロファイルは `WORK_DIR/Projects/<プロジェクト>/profiles/` に住む。
  Projects/ が1つならそれ。複数なら🧑どのプロジェクトかを確認する。
- **ftester CLI の在り処**: clone 構成は `swift run ftester ...`、外部パッケージ構成は
  `<TOOL_ROOT>/.build/debug/ftester ...`(TOOL_ROOT は WORK_DIR/Package.swift の `.package(path:)` から
  解決。無ければ既定の `../foundation-tester`。判定は `Sources/FTScenarioRunner/` の有無)。
  以降 `ftester` はこれを指す。
- **原則**: 各書き込みの後に検証ゲート(`ftester profile list`)を通す。🧑 は停止して確認する。
  **人に聞くときは必ず AskUserQuestion(ダイアログ)を使う** — チャットに質問文を書いて答えを待たない
  (テキストで聞くと見落とされ、フローが止まる)。自由入力は Other で受ける。
  「それ以外のパラメータは既定」— 明示的に聞いた値以外は書かない(未指定=デフォルト)。

## 手順

### 1. 🧑 プラットフォームを確認

まず **iOS か Android か** をユーザーに確認する(AskUserQuestion)。以降 `<plat>` = `ios` または `android`。

### 2. 🧑 アプリ情報を確認

次の2つを聞く(自由入力):

- **アプリの表示名**(`appName`。例 `SUTStore`)
- **アプリID**(iOS は bundle ID、Android はパッケージ名。例 `com.sutec.mobile`。
  **分からなくても中断しない**: init 由来プロファイルの既存値(プレースホルダ `com.example.myapp` 含む)の
  まま進め、実行前に `profiles/apps/` の `app` を実IDへ差し替える必要があることを 🧑 に伝えて
  ステップ7の報告にも残す)

**パッケージパス(`appPath`)は聞かない**。ユーザーが自発的に伝えてきた場合のみ使う
(ビルド済み `.app`/`.apk`。相対は WORK_DIR 基準・`~`・絶対可)。未指定なら省略する
(後から `profiles/apps/` を編集して向けられる)。

`appRef`(アプリプロファイルのファイル名)は `appName` を小文字化・`^[a-z0-9_-]+$` に整えた値にする
(例 `SUTStore` → `sutstore`)。整えられない文字が多ければ🧑に確認する。

### 3. 🧑 デバイス(マシンプロファイル)の指定を確認

**「デバイスについて指定したいものはあるか」** を聞く。指定できるのは:

- 機種(iOS: シミュレータ機種 / Android: AVD デバイス定義)
- OS バージョン(iOS: ランタイム / Android: システムイメージ)
- デバイスの論理名(実行プロファイルから参照する `name`)

**指定がなければ既定**: そのマシンで **利用可能な最新 OS** の仮想デバイスを使う。無ければ作成する
(下のステップ4のアルゴリズム)。論理名の既定は iOS `simulator1` / Android `emulator1`(scaffold の runs 雛形と対)。

### 4. デバイスを決める(選ぶ / 無ければ作る)

マシン名(プロファイルのファイル名)を決める: `ftester machine show` の登録名 → `FT_MACHINE` →
`profiles/machines/` に .json が1つならそれ → いずれも無ければ `scutil --get ComputerName` を整えた名前で
`ftester machine set "<名>"` して登録。プロファイルは `profiles/machines/<マシン名>.json`。

**既にそのマシンプロファイルへ `<plat>` のデバイスが登録済みなら、新規の選定・作成はしない**
(/ftester-setup のステップ5が自動作成済みのケース。二重登録を防ぐ)。既存デバイスの論理名を
ステップ6で参照する。ユーザーが機種/OS を明示指定し、既存に合うものが無いときだけ追加する。

デバイスを選定/作成する。**論理名は ios/android 横断で一意**にする(重複したら末尾に連番)。

#### 4-a. 最新 OS の判定(権威は device-catalog。simctl の一覧は未ソートなので使わない)

```
ftester api device-catalog
```

- iOS: `ios.runtimes[0]`(最新ランタイム。`identifier`/`version`)、`ios.deviceTypes[0]`(既定機種。
  `identifier`/`name`)。
- Android: `android.systemImages[0]`(最新イメージ。`package`)、`android.models[0]`(既定機種。`id`)。

ユーザーが機種/OS を **指定した** 場合は、その指定に合う `identifier`/`package`/`id` を catalog から選ぶ。

#### 4-b. 既存の仮想デバイスがあれば使う / 無ければ作成する

- **iOS**:
  - `xcrun simctl list devices available -j` の `devices["<最新ランタイムの identifier>"]` を見る。
    - 1台以上あれば1つ選ぶ(名前に "Pro" を含むものを優先、無ければ先頭)。機種名・version・udid を
      控えておき、ステップ5の `profile setup` に渡す(`--simulator`/`--os`/`--udid`。
      `udid` があれば `simulator`/`os` より優先される)。
    - 0台なら **作成**する(下記 create-device)。
- **Android**:
  - `emulator -list-avds` に AVD があれば1つ選ぶ(新しめを優先)。AVD ID を控えて
    ステップ5の `profile setup --avd <avdID>` に渡す。
  - 無ければ **作成**する。`android.models` が空の環境では device 定義 id が採れないため、
    `avdmanager list device` を見て🧑に機種 id を確認する。

**作成(create-device)** は、対象のマシンプロファイルが既に存在している必要がある。無ければ先に
`ftester profile setup`(ステップ5)を1回実行して作る、または空のデバイス配列
(`{ "<plat>": { "devices": [] } }`)を置く。その後:

```
ftester api create-device --project <プロジェクト> --machine <マシン名> \
  --platform <plat> --name "<論理名>" --model "<機種 identifier/id>" --os "<ランタイム identifier / システムイメージ package>"
```

- iOS: `--model` = `deviceTypes[i].identifier`、`--os` = `runtimes[i].identifier`。
- Android: `--model` = `models[i].id`、`--os` = `systemImages[i].package`。
- create-device はシミュレータ/AVD を新規作成し、マシンプロファイルへ自動で追記する
  (NDJSON `finished` の `ok` を確認。失敗時 exit 1)。

> **マシンプロファイルへの追記は自分でしない**。既存デバイスを使う場合はステップ5の
> `ftester profile setup` に実体(`--simulator`/`--udid`/`--avd`/`--serial`)を渡す。作成する場合は
> create-device が追記済みなので、ステップ5では `--device-name` だけ渡す(二重登録を防ぐ)。

### 5. プロファイルを書く(**手書きしない**)

マシン/アプリ/実行の3ファイルは **`ftester profile setup` が1コマンドで整合させて書く**。
JSON を手で書くと machines の `name` と runs の参照名がずれる・指示していないプラットフォームの
run が残る、という不整合が起きるため、**エージェントが JSON を直接書かない**こと(冪等・再実行可)。

```
ftester profile setup --project <プロジェクト> --platform <plat> \
  --device-name <論理名> [--simulator "<機種名>" --os <version> | --udid <UDID> | --avd <avdID> | --serial <シリアル>] \
  --app-id <アプリID> --app-name "<表示名>" [--app-path <パッケージパス>] [--machine <マシン名>] [--app-ref <ref>]
```

- **ステップ4で create-device が作った/既存を選んだ場合**は実体の指定を省ける(`--device-name` だけ)。
  その名前が machines に無ければエラーになる(黙って別物を作らない)。
- `--app-path` は入力があったときだけ渡す(渡すと `autoInstall` が有効になる)。
- `--app-ref` 省略時はプロジェクト名の小文字。既存の `apps/<ref>.json` があればマージする
  (未知キーは温存)。`--machine` 省略時は登録名 → `machines/` が1つならそれ。
- 書いた実行プロファイルが解決できるかまでコマンド内で検証し、解決結果を表示する。

### 6. 検証ゲート

```
ftester profile list --project <プロジェクト>
```

作った実行プロファイル `<plat>` が **アプリ名・デバイス @ マシン名** まで解決し、`❌`/`⚠️` が出ない
ことを確認してユーザーに要約報告する。赤が出たら原因(デバイス名の不一致・アプリパス不在など)を
そのまま見せて相談する。

## 完了後

- 実行: `ftester run --project <プロジェクト> --profile <plat>`(実機シミュレータ/エミュレータが要る)。
- 別プラットフォームや別アプリを足すときは、この `/ftester-profiles` をもう一度実行する
  (マシンプロファイルには追記、アプリ/実行プロファイルは新しい `appRef`/`<plat>` で追加)。
