---
name: ftester-profiles
description: ftester のマシンプロファイル・アプリプロファイル・実行プロファイルを1回のフローでまとめて作成する。最初に iOS/Android を確認し、アプリの表示名・アプリIDを聞き(パッケージパスは聞かない)、デバイスは指定があればそれで、無ければそのマシンで利用可能な最新OSの仮想デバイス(無ければ作成)で用意する。「プロファイルを作って」「デバイスとアプリと実行プロファイルをまとめて用意して」「テスト対象を追加して」等の依頼で使う。
---

# ftester プロファイル一括作成 runbook

> **ユーザーへの質問(AskUserQuestion)・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


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

- **プロジェクトと WORK_DIR**: プロファイルは `WORK_DIR/TestProjects/<プロジェクト>/profiles/` に住む。
  TestProjects/ が1つならそれ。複数なら🧑どのプロジェクトかを確認する。
- **ftester CLI の在り処**: clone 構成は `swift run ftester ...`、外部パッケージ構成は
  `<TOOL_ROOT>/.build/debug/ftester ...`(TOOL_ROOT は WORK_DIR/Package.swift の `.package(path:)` から
  解決。無ければ既定の `../foundation-tester`。判定は `Sources/FTScenarioRunner/` の有無)。
  以降 `ftester` はこれを指す。
- **原則**: 各書き込みの後に検証ゲート(`ftester profile list`)を通す。🧑 は停止して確認する。
  **既に分かっている値は聞き直さない** — `/ftester-setup` から呼ばれた場合はプロジェクト名・
  アプリ表示名・アプリID・プラットフォーム・マシン名が確定済み。**足りない値だけ**を聞く
  (同じことを二度聞かれるのは、受け手にとって最も目に付く無駄)。
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

### 4. プロファイルを作る(**1コマンド。JSON は手書きしない**)

マシン/アプリ/実行の3ファイルは `ftester profile setup` が整合させて書く(冪等・再実行可)。
**デバイスの選定もコマンドに任せる**(`--auto-device`)。
`ftester api device-catalog` / `simctl list` / `emulator -list-avds` を別々に叩かない
(承認回数が増えるだけで、選定規則はコマンド側に入っている):

```
ftester profile setup --project <プロジェクト> --platform <ios|android|both> --auto-device \
  --machine <マシン名> --app-id <アプリID> --app-name "<表示名>" [--app-path <パッケージパス>] [--app-ref <ref>]
```

- `--auto-device` の選定規則: **iOS = 最新 OS の既存シミュレータ(iPad は除外・名前に "Pro" を含むものを優先)** /
  **Android = config.ini の API レベルが最大の既存 AVD**。0台なら作成方法を示してエラーになる。
- `--platform both` で iOS と Android を1回で作る(論理名は simulator1 / emulator1)。
- `--machine` はマシンプロファイル名(`profiles/machines/<名前>.json`)。作った実行プロファイルには
  その名前が `"machine"` として書かれる(この Mac の登録名という概念は無い)。
- 機種/OS をユーザーが指定した場合だけ `--auto-device` を外し、実体を明示する
  (iOS: `--simulator "<機種名>" --os <version>` か `--udid`、Android: `--avd <avdID>` か `--serial`)。
- 仮想デバイスを**新規作成**する必要があるとき(0台・指定に合うものが無い)は
  `ftester api create-device`(→ 下の 4-b)で作ってから、`profile setup --device-name <作った名前>` を呼ぶ。
- `--app-path` は入力があったときだけ渡す(渡すと `autoInstall` が有効になる)。

#### 4-b. 新規作成が要るとき(create-device)

```
ftester api create-device --project <プロジェクト> --machine <マシン名> \
  --platform <plat> --name "<論理名>" --model "<機種 identifier/id>" --os "<ランタイム identifier / システムイメージ package>"
```

`--model` / `--os` の値は `ftester api device-catalog` の
`ios.deviceTypes[i].identifier` / `ios.runtimes[i].identifier`(Android は `android.models[i].id` /
`android.systemImages[i].package`)。**このカタログ取得は新規作成のときだけ**行う。

Android のシステムイメージは同じ OS バージョンでも Play Store 版(`...;google_apis_playstore;...`)と
Google APIs 版(`...;google_apis;...`)がある。**指定が無ければ `google_apis` を選ぶ**
(モニターの「デバイスを追加」の既定と揃える。Play ストアが要るテストのときだけ playstore 版)。

Android で `android.models` が空(`android.errorCode` = `avdmanager-missing`)なら cmdline-tools が
未導入。`ftester api install-cmdline-tools` で導入できる(約150MB・数分)。**勝手に走らせず**
AskUserQuestion で導入の可否を聞いてから実行し、終わったら device-catalog を取り直す。

### 5. 検証ゲート

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
