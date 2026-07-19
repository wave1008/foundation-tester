---
name: ftester-profiles
description: ftester のマシンプロファイル・アプリプロファイル・実行プロファイルを1回のフローでまとめて作成する。最初に iOS/Android を確認し、アプリの表示名・アプリID・パッケージパス(任意)を聞き、デバイスは指定があればそれで、無ければそのマシンで利用可能な最新OSの仮想デバイス(無ければ作成)で用意する。「プロファイルを作って」「デバイスとアプリと実行プロファイルをまとめて用意して」「テスト対象を追加して」等の依頼で使う。
---

# ftester プロファイル一括作成 runbook

1つのアプリ×1プラットフォーム分の **マシン/アプリ/実行プロファイルの三点セット** を作る。
既存プロジェクト(`ftester project create` / `ftester init` 済み)に対して実行する。未セットアップなら
`/ftester-setup` を案内する。

## 前提の確定(最初に1回)

- **プロジェクトと WORK_DIR**: プロファイルは `WORK_DIR/Projects/<プロジェクト>/profiles/` に住む。
  Projects/ が1つならそれ。複数なら🧑どのプロジェクトかを確認する。
- **ftester CLI の在り処**: clone 構成は `swift run ftester ...`、外部パッケージ構成は
  `../foundation-tester/.build/debug/ftester ...`(setup と同じ TOOL_ROOT/WORK_DIR。判定は
  `Sources/FTScenarioRunner/` の有無)。以降 `ftester` はこれを指す。
- **原則**: 各書き込みの後に検証ゲート(`ftester profile list`)を通す。🧑 は停止して確認する。
  「それ以外のパラメータは既定」— 明示的に聞いた値以外は書かない(未指定=デフォルト)。

## 手順

### 1. 🧑 プラットフォームを確認

まず **iOS か Android か** をユーザーに確認する(AskUserQuestion)。以降 `<plat>` = `ios` または `android`。

### 2. 🧑 アプリ情報を確認

次の3つを聞く(自由入力):

- **アプリの表示名**(`appName`。例 `SUTStore`)
- **アプリID**(iOS は bundle ID、Android はパッケージ名。例 `com.sutec.mobile`)
- **パッケージパス**(`appPath`。**任意** — ビルド済み `.app`/`.apk`。相対は WORK_DIR 基準・`~`・絶対可)。
  未入力なら省略してよい(後から `profiles/apps/` を編集して向けられる)。

`appRef`(アプリプロファイルのファイル名)は `appName` を小文字化・`^[a-z0-9_-]+$` に整えた値にする
(例 `SUTStore` → `sutstore`)。整えられない文字が多ければ🧑に確認する。

### 3. 🧑 デバイス(マシンプロファイル)の指定を確認

**「デバイスについて指定したいものはあるか」** を聞く。指定できるのは:

- 機種(iOS: シミュレータ機種 / Android: AVD デバイス定義)
- OS バージョン(iOS: ランタイム / Android: システムイメージ)
- デバイスの論理名(実行プロファイルから参照する `name`)

**指定がなければ既定**: そのマシンで **利用可能な最新 OS** の仮想デバイスを使う。無ければ作成する
(下のステップ4のアルゴリズム)。論理名の既定は iOS `メイン機` / Android `エミュ1`。

### 4. マシンプロファイルの用意

マシン名(プロファイルのファイル名)を決める: `ftester machine show` の登録名 → `FT_MACHINE` →
`profiles/machines/` に .json が1つならそれ → いずれも無ければ `scutil --get ComputerName` を整えた名前で
`ftester machine set "<名>"` して登録。プロファイルは `profiles/machines/<マシン名>.json`。

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
    - 1台以上あれば1つ選ぶ(名前に "Pro" を含むものを優先、無ければ先頭)。マシンプロファイルへ
      デバイスを追記(直接編集): `{ "name": "<論理名>", "simulator": "<機種名>", "os": "<version>", "udid": "<udid>" }`
      (`udid` があれば `simulator`/`os` より優先される。両方書いておくと可読)。
    - 0台なら **作成**する(下記 create-device)。
- **Android**:
  - `emulator -list-avds` に AVD があれば1つ選ぶ(新しめを優先)。追記:
    `{ "name": "<論理名>", "avd": "<avdID>" }`。
  - 無ければ **作成**する。`android.models` が空の環境では device 定義 id が採れないため、
    `avdmanager list device` を見て🧑に機種 id を確認する。

**作成(create-device)** は、対象プロファイルが既に存在している必要がある。無ければ先に空のデバイス配列で
用意する(例 `{ "<plat>": { "devices": [] } }`)。その後:

```
ftester api create-device --project <プロジェクト> --machine <マシン名> \
  --platform <plat> --name "<論理名>" --model "<機種 identifier/id>" --os "<ランタイム identifier / システムイメージ package>"
```

- iOS: `--model` = `deviceTypes[i].identifier`、`--os` = `runtimes[i].identifier`。
- Android: `--model` = `models[i].id`、`--os` = `systemImages[i].package`。
- create-device はシミュレータ/AVD を新規作成し、マシンプロファイルへ自動で追記する
  (NDJSON `finished` の `ok` を確認。失敗時 exit 1)。

> 既存デバイスを使う場合は直接編集で追記、作成する場合は create-device が追記する。二重登録しないこと。

### 5. アプリプロファイルを作る

`profiles/apps/<appRef>.json` を書く。**フィールドの置き場所は固定**(`AppProfileSection.merging`):
`appName`=common、`autoInstall`=common のみ、`app`(ID)と `appPath`=platform セクションのみ。

```json
{
  "common": { "appName": "<表示名>", "autoInstall": <appPath があれば true・無ければ false> },
  "<plat>": { "app": "<アプリID>", "appPath": "<パッケージパス>" }
}
```

- `appPath` は入力があったときだけ書く(未入力なら `appPath` 行を省く。`autoInstall` は false)。
- `common` に `app`/`appPath` を書かない(無視され validate が警告する)。

### 6. 実行プロファイルを作る

`profiles/runs/<plat>.json` を書く(scaffold の同名雛形があれば正しい値で上書き)。デバイスは
ステップ4で決めた論理名を参照する。**それ以外は既定**(`heal` false、タイムアウト等は書かない):

```json
{
  "app": "<appRef>",
  "devices": [ { "name": "<論理名>" } ],
  "heal": false,
  "reportDir": "reports"
}
```

### 7. 検証ゲート

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
