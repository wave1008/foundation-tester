---
name: ftester-setup
description: foundation-tester を使いたい受け手を、自分の iOS/Android アプリ向けにシナリオを書いて実行できる状態まで初期セットアップする。未クローンなら clone から行い、ビルド・環境検証・自分のプロジェクト作成・マシン/アプリのプロファイル設定・VSCode 拡張のインストールを、検証ゲートと人間チェックポイント付きで順に実行する。「セットアップして」「使えるようにして」「動かせるようにして」等の初回導入依頼で使う。
---

# ftester 初期セットアップ runbook

> **ユーザーへの質問(AskUserQuestion)・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **この手順書が古い可能性がある**: プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` のスナップショットから読まれており `git pull` では更新されない。
> **clone(TOOL_ROOT)が既にあるなら `<TOOL_ROOT>/.claude/skills/ftester-setup/SKILL.md` を読み、
> 内容が違えばそちらを正とする**。更新は `claude plugin marketplace update foundation-tester` →
> `claude plugin update ftester@foundation-tester`(2つとも要る・Claude Code の再起動で反映)。
> **`/plugin` スラッシュコマンドは VSCode 拡張・Agent SDK 環境では提供されない**ので CLI 形を使う。

受け手を、**自分のアプリのシナリオを書いて実行できる状態**まで導く。
全体像・背景は docs/userDocs/getting-started_ja.md。ここはエージェントが順に実行するための手順書。

**入り方は2通り。ステップ 0.5 で判定する:**

- **外部パッケージ構成(既定・curl でスキルだけ入れた受け手ディレクトリ)**: いま開いているこの
  ディレクトリを ftester テストパッケージにする。**あなたのプロジェクト(`TestProjects/<name>/`)は
  この受け手ディレクトリに作られる**。foundation-tester は「ツール(CLI・拡張)」として横に clone+build
  するだけで、Projects はここに住む。作成は `ftester init`。
- **clone 構成(foundation-tester クローンの中で直接作業する保守者/PoC)**: Projects はクローンの
  `TestProjects/` に作る。作成は `ftester project create`。

以降、**TOOL_ROOT** = foundation-tester クローン(swift build / doctor / 拡張ビルドを行う場所。CLI は
`TOOL_ROOT/.build/debug/ftester`)、**WORK_DIR** = `TestProjects/` が住む作業ディレクトリ、と呼ぶ。
外部構成では WORK_DIR = このカレント・TOOL_ROOT = clone 先(**既定は隣の `../foundation-tester`**。
ユーザーが指定すればそのパス)。clone 構成では両者は同一(クローン)。

## 進め方の原則

- **各ステップの後に検証ゲートを通す**（exit code / doctor / 到達確認）。緑になるまで次へ進まない。
- **人間チェックポイント（🧑）では必ず停止して依頼・確認する**。エージェントでは代行できない。
- **人に何かを聞くときは必ず AskUserQuestion（ダイアログ）を使う**。チャットに質問文を書いて
  答えを待たない（テキストで聞くと見落とされ、フローが止まる）。自由入力は Other で受ける。
- **セットアップ値は探索せず人間に聞く**：Bundle ID・App ID・ビルド済み `.app`/`.apk` のパス・
  テスト対象アプリの所在などを、兄弟ディレクトリや別リポジトリを勝手に `find`/`grep` で探索して
  確定してはならない。値は人間から得る（`appPath` のように**聞かない**値は、人間が自発的に示すまで
  未設定のままにする。探索で見つけた候補を既定値として提示するのも避ける）。
  「質問を減らすため」の事前調査も禁止。
- **冪等に**：既に済んでいる状態を検出したらスキップする（再実行に強く）。
- 失敗したら握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

## 手順

### 0. 前提の機械判定と一括質問

**まず状態判定スクリプトを実行する**(構成・既存クローン・環境を1回で判定する。読み取りのみ):

```
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/preflight.sh | bash
```

(クローンがあるなら `bash <TOOL_ROOT>/Scripts/preflight.sh`。**カレント = WORK_DIR 候補**を判定する。)
出力は `key=value` 行 + 判定。**終了コードで分岐する**:

- **0 = ready** → 未導入。ステップ0の質問へ進む。`tool_root_exists=` / `cli_built=` で既存クローンの有無も分かる。
- **2 = installed** → 導入済み。**セットアップを続けない**(下の再実行ガードと同じ扱い)。用途別に案内する。
- **1 = blocked** → 導入不可。**出力の理由行をそのまま 🧑 に見せて対処を依頼する**(理由ごとに対処が違い、
  `xcode_error=` と `xcode_select_path=` から切り分け済みの具体的なコマンドが出る。
  license 未同意なら `sudo xcodebuild -license accept`、CommandLineTools が選択されているなら
  `sudo xcode-select -s /Applications/Xcode.app`)。**自分で原因を推測して別のコマンドを案内しない**。
  sudo や Xcode 導入は代行できない。

以下は同じ判定を手で行う場合の内訳(スクリプトが使えないとき)。

**導入済み判定(再実行ガード)**: カレントに `Package.swift` があり `Sources/FTScenarioRunner/` が
**無い**場合、質問をする前に `Package.swift` の**中身**で二分する(ファイルの有無だけで判定しない —
受け手が自分のアプリの既存リポジトリで実行したケースと区別がつかない):

- **ftester マーカー(`// === ftester projects begin`)か foundation-tester への `.package` 依存が無い** =
  ftester と無関係の Swift パッケージ。ここには導入できない(`ftester init` が拒否する)。**中止**して、
  テスト専用の新規ディレクトリで実行し直すよう 🧑 に案内する。
- **ある** = 外部パッケージ構成が確立済み。このセットアップは**実行済み。ここで中止**し、
  用途別に案内する:
  - ツールの更新 → `/ftester-update`
  - デバイス・アプリ・実行プロファイルの追加 → `/ftester-profiles`
  - シナリオの作成 → `/ftester-scenario`
  - **再インストール**(clone 先の変更・導入のやり直し)→ **まずアンインストールを 🧑 に案内**し、
    完了を確認してから `/ftester-setup` を再実行する。手順は docs/userDocs/getting-started_ja.md「アンインストール」
    (3層+ WORK_DIR 側の生成物削除。`TestProjects/` は資産なので残してよい)。アンインストール前に
    セットアップを続行しない。`Package.swift` 等の部分的な書き換えで済まさない(1箇所でも残すと
    旧 clone と新 clone に分裂し、更新が旧側に当たり続ける)

別の clone 先の指定があっても init をやり直さない(`Package.swift` の依存とズレるスプリットブレイン防止)。
clone 構成(両方ある)の再実行は従来どおり冪等スキップで続行してよい。

**環境は機械判定する（人間に「入っているか」を聞かない）**。失敗した項目だけ 🧑 停止して対処を依頼する
（導入・license 同意はエージェントでは代行不可）:

- macOS 26+: `sw_vers -productVersion`（macOS 26 では FM の視覚検証 = occlusion-guard / screenLooksLike
  だけが使えない。画像入力が macOS 27+ のため。中断せず続行し、完了報告にその旨を残す）
- Xcode 26+: `xcodebuild -version`（コマンド自体が license 未同意エラーで落ちたら 🧑 に
  `sudo xcodebuild -license accept` を依頼。sudo は代行不可）
- 初回セットアップ: `xcodebuild -checkFirstLaunchStatus`（exit 0 以外なら 🧑 に `xcodebuild -runFirstLaunch` を依頼）

**セットアップ値は 🧑 に冒頭の1回でまとめて質問する**（以降のステップで散発的に再質問しない）。
**必ず AskUserQuestion（ダイアログ）で聞く。チャットに箇条書きで質問文を書いて答えを待ってはいけない**
（実際にテキストで聞いてしまい、ユーザーがダイアログを受け取れなかった事故がある）。
**1回の AskUserQuestion 呼び出しに次の4問をまとめる**（各問に選択肢を用意する。自由入力は Other で受ける）:

| 質問 | header | 選択肢（先頭を推奨にする） |
|---|---|---|
| プロジェクト名（英数字 `^[A-Za-z0-9_][A-Za-z0-9_-]*$`。SPM ターゲット名になる） | Project | カレントフォルダ名から作った候補（推奨）/ `MyAppTests` / Other=自由入力 |
| テスト対象アプリの bundle ID | Bundle ID | 「まだ分からない（後で設定）」/ Other=自由入力 |
| テスト対象アプリの表示名（プロファイルの `appName`） | App | フォルダ名から作った候補 / Other=自由入力 |
| テスト対象のプラットフォーム | Platform | iOS / Android / 両方 |

**マシン名(= マシンプロファイル名)と clone 先は聞かない**（マシン名は preflight の
`computer_name=`、clone 先は `tool_root=`。どちらも完了報告で伝えれば足りる)。
受け手が別の clone 先を明示した場合だけ追加で 1 問聞く。

- bundle ID は**分からなくても中断しない**。「まだ分からない」ならプレースホルダ `com.example.myapp` の
  まま続行する（実IDが要るのは実行(launch)時だけ。後から `profiles/apps/<projectname>.json` の `app` を
  差し替えれば済む →ステップ6）。
- **選択肢の候補は preflight の出力をそのまま使う**(`folder_name=` → プロジェクト名、
  `computer_name=` → マシンプロファイル名の既定)。
  `scutil` や `basename` を別途実行しない(承認回数が増えるだけ)。**他リポジトリを探索して埋めない**。
- clone 先は外部パッケージ構成のみ関係（→ステップ0.5）。指定があればそのパスが TOOL_ROOT。

**ビルド済み `.app`/`.apk` のパス（`appPath`）はセットアップでは聞かない**（→ステップ6。
後から `profiles/apps/` を編集して設定できる）。

→ **これらは人間に聞く。他リポジトリを勝手に探索して埋めない**（バージョン・パスの推測は事故のもと。
探索で見つけた候補を既定値として提示するのも避ける）。
（シミュレータは step 5 で自動採取・自動選択するのでここでは聞かない。）

### 0.5 入り方の判定と TOOL_ROOT の取得

カレントか祖先に `Package.swift` と `Sources/FTScenarioRunner/` の**両方**があるかで判定する
(この2つが揃うのは foundation-tester クローンだけ):

- **両方ある = clone 構成**: いま foundation-tester クローンの中にいる。TOOL_ROOT = WORK_DIR =
  そのディレクトリ。取得不要でステップ1へ。
- **無い = 外部パッケージ構成(既定)**: WORK_DIR = このカレント(ここに TestProjects/ を作る)。
  ツールを供給するため foundation-tester を**兄弟ディレクトリ**に clone+build する(受け手の
  ディレクトリの中にネストさせない):

```
git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester
```

  ※ **clone 自体はステップ0.7 のインストーラが行う**ので、ここでは clone 先(TOOL_ROOT)を決めるだけでよい
  (既に clone 済みならそれを使う)。上のコマンドはインストーラを使わないときの手順。

  → TOOL_ROOT = `../foundation-tester`。**ステップ0で clone 先の指定があればそちらへ clone し、
  以降この runbook の `../foundation-tester` はそのパスに読み替える**(指定先に clone 済みならスキップして
  それを TOOL_ROOT にする)。WORK_DIR 配下へのネストは非推奨(init の .gitignore 整備の対象外で
  git ノイズになる)。build / doctor / 拡張ビルドは TOOL_ROOT で、`ftester init` と
  プロファイル設定は WORK_DIR(カレント)で行う。**カレントに `Package.swift` があってはいけない**
  (`ftester init` が拒否する。既存 repo の直下ではなく、テスト専用の新規ディレクトリで実行する)。

版を固定したい場合は 🧑 に確認して TOOL_ROOT で `git checkout <tag>`(配布はソースビルド前提なので
tag も clone で取得できる)。

### 0.7 インストーラで機械作業を一括実行（**まずこれを試す**）

ステップ **0.5・1・2・2.5・3・4・5・7・7.5・7.6** はインストーラが一括で行う（冪等。済んだ手順は skip される。
**既存クローンは `git pull --ff-only` で更新してから使う** — ローカル変更があれば
**端末で破棄の可否を尋ね、破棄しないなら中止する**（古いクローンのまま build させないため。
端末が無い＝エージェント実行では尋ねられないので必ず中止 `[fail]` になる。その場合は 🧑 に
`git -C <TOOL_ROOT> stash`（残したい）か `reset --hard`（捨ててよい）を依頼してから再実行する）。
版固定（detached）は触らない）。
ステップ0で聞いた値を引数で渡すだけで、**探索はしない**（appPath・bundle ID を勝手に埋めない設計）。

```
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh | bash -s -- \
  --name <ProjectName> --platform <ios|android|both> --machine <マシン名> --app-name "<表示名>" [--app-id <bundleID>]
```

**`--machine` と `--app-name` を渡すとプロファイル作成(`profile setup --auto-device`)まで1回で終わる**
(ステップ5・8 が不要になる。デバイスは自動選定)。値はすべてステップ0の回答と preflight の出力から作る。

- **curl 形を使う**（クローンの `Scripts/install.sh` は pull されるまで古く、新しい引数を渡すと
  「不明なオプション」で落ちる。curl 形なら常に最新が動き、その中でクローンを pull する）。
  clone 先を変えるなら `--tool-root <dir>`。オフラインなど curl が使えないときだけ
  `bash <TOOL_ROOT>/Scripts/install.sh --work-dir <WORK_DIR> …` を使う。
- clone 構成（TOOL_ROOT = WORK_DIR）でもそのまま使える（`--work-dir` にクローンを渡す。
  `ftester init` ではなく `project create` 経路になり、`.mcp.json` は同梱のものが使われる）。

**出力の読み方**（行頭の `[ok]` / `[skip]` / `[warn]` / `[fail]` が機械可読部）:

各ステップは**終わった時点で1行ずつ**出る（数分かかる工程には経過時間が付く）。最後の
「Install results」は**集計と warn/fail の再掲だけ**なので、`[ok]` 行を見たいときは
出力全体から拾う（同じ書式）。`swift build` などの生ログは画面に出ず
`<WORK_DIR>/.ftester/install-<日時>.log` にある。**ログを grep で漁らない**（必要なら `--verbose`）。

- **exit 0** → 機械作業は完了（プロファイルまで済んでいれば `[ok] プロファイル` が出る）。**ステップ6へ**。
- **exit 2** → 必須は通ったが任意ステップが未完（`[warn]` 行）。CLI と MCP は使える。
  warn 行が指す**下のステップ番号の手順だけ**を手で通し、原因を直してから同じ引数で再実行する。
- **exit 1** → 必須ステップで停止（`[fail]` 行に「→ SKILL.md step N」が出る）。
  **N の手順を読んで原因を解決し、同じ引数で再実行する**（済んだ手順は skip されるので巻き戻らない）。
  解決に人間の操作が要るもの（Xcode の license 同意・`-runFirstLaunch`・Homebrew 導入）は 🧑 に依頼する。

**以降のステップ1〜5・7・7.5 は「インストーラが失敗したときの手作業手順」**（成功したなら読み飛ばしてよい）。
必ず実施するのは **6（appPath/bundle ID の案内）・9（反映操作の案内）** だけ。

**インストーラの出力に載っている情報を、別コマンドで取り直さない**（承認が増えるだけ）:

| 取り直しがちなもの | 既にどこに出ているか |
|---|---|
| TOOL_ROOT の絶対パス（`cd … && pwd`） | preflight の `tool_root=` / インストーラの `[ok] 構成` |
| `.mcp.json` の内容（`cat`） | インストーラの `[ok] MCP` |
| `ftester doctor --roots-only` | インストーラが検証ゲートとして実行済み（`[ok] ルート解決`) |
| `ftester profile list` | `profile setup` が解決結果を表示済み（`[ok] プロファイル`） |

### 1. xcodegen

`command -v xcodegen` で確認。無ければ `brew install xcodegen`（未導入だと iOS ブリッジ生成が失敗する）。

### 2. ビルド

**TOOL_ROOT で** `swift build`（初回は数分）。**exit code で成否を判定**（パイプで grep に繋がない）。
これで `TOOL_ROOT/.build/debug/ftester`(CLI 本体)が揃う。以降 `ftester` はこのバイナリを指す。

### 2.5 Apple Intelligence 自動判定（人間に聞かない・**不可でも続行**）

**TOOL_ROOT で** `swift run ftester doctor --fm-only` を実行する。これは `SystemLanguageModel.default.availability`
（オンデバイス FM／Apple Intelligence の可否）だけを見て **exit code で返す**（可=0／不可=1）。
**FM は必須ではない** — 使うのは heal（自己修復）・FM 視覚検証（`screenLooksLike` 等）・シナリオ生成/探索
（`/ftester-scenario` の頭脳）だけで、決定的なシナリオ実行・VSCode 拡張・MCP のデバイス操作・dry-run は
FM 無しで動く。**人間に「有効か」を聞かない**：

- **exit 0**（`✅ 利用可能`）→ 次へ。
- **exit 1**（無効／ダウンロード中／対象外）→ **セットアップは中断せず続行する**。有効化のための
  停止・待機・質問はしない。理由を控えておき、ステップ9の完了報告に
  「Apple Intelligence 要有効化（FM 機能を使う場合）」として残す：後から System 設定 →
  Apple Intelligence & Siri でオンにし、`ftester doctor --fm-only` が ✅ になれば heal・視覚検証・
  シナリオ生成がそのまま使えるようになる（セットアップのやり直しは不要）。

### 3. 環境検証ゲート

**TOOL_ROOT で** `swift run ftester doctor` を実行し、出力をユーザーに要約して見せる（FM/AI は 2.5 で判定済み。
**FM の赤はここでも続行してよい** — 2.5 の方針どおり完了報告に残すだけ）。
それ以外の赤（未導入・無効）が残る項目は、ステップ0に戻って人間に対処を依頼してから再実行。次へ。

### 4. 自分のプロジェクトを作る(構成で分岐)

ステップ0で確認したプロジェクト名と bundle ID を使い、**WORK_DIR(カレント)で**作る:

- **外部パッケージ構成(既定)**: `ftester init` で WORK_DIR を ftester テストパッケージにする。
  TOOL_ROOT を SPM のローカルパス依存として引き、最初のプロジェクトを登録する:

```
../foundation-tester/.build/debug/ftester init \
  --ftester-path ../foundation-tester --name <ProjectName> --app <bundleID>
```

  bundle ID が未確定なら `--app` を**省略**する(既定のプレースホルダ `com.example.myapp` で作成される)。

  → WORK_DIR に `Package.swift`(空マーカー区間 + ftester 依存)と `TestProjects/<ProjectName>/`、
  `.vscode/settings.json`(`ftester.binaryPath`・`ftester.project`。拡張の手動設定を不要にする)が生成され、
  受け手専用の `/ftester-setup` スキルが `.claude/skills/` に上書きされる(次回以降の実行はそちらを使う。
  この実行はロード済み手順のまま継続してよい)。ローカルパス依存なので `swift build` はネットワーク不要・
  TOOL_ROOT を `git pull` すれば ftester 側も更新される。git 依存にしたい場合のみ `--ftester-url
  https://github.com/wave1008/foundation-tester.git --ftester-version <ver>` を使う(`--ftester-path` と排他。
  **git 依存では `.vscode/settings.json` の `ftester.binaryPath` が自動設定されない** — CLI・拡張は
  ローカル clone からのビルドが別途必要なので、拡張を使うなら path 依存を推奨し、git 依存を選んだら
  binaryPath の手動設定を 🧑 に案内する)。
  以降このスキル内で `ftester ...` と書いたら `../foundation-tester/.build/debug/ftester ...` を実行する。

- **clone 構成**: TOOL_ROOT(=WORK_DIR)で `swift run ftester project create <ProjectName> --app <bundleID>`。
  `TestProjects/<ProjectName>/` と Package.swift のターゲット登録が生成されたことを確認する。

**検証ゲート(init 後の .gitignore)**: WORK_DIR が git リポジトリ(既存 repo 直下を含む)なら、
`.gitignore` に `.build/` と `TestProjects/*/reports/` があることを確認する(`ftester init` が自動整備する。
欠けていればこの2行を追記)。`git status` に `.build/` の未追跡ノイズが出ないことまで見る。
何をコミットすべきかを受け手に案内する: `Package.swift`・`Package.resolved`・`TestProjects/`・`.gitignore` は
コミット、`.build/` と `TestProjects/*/reports/` は ignore(init が整備済み)。`.mcp.json` は TOOL_ROOT の
絶対パスを含むためマシン固有。

### 5. プロファイル（マシン/アプリ/実行）

**JSON を手で書かない・デバイス調査のコマンドを個別に叩かない**。作成は `/ftester-profiles`
（ステップ8で呼ぶ）に任せる。自分で通すなら1コマンドで済む:

```
ftester profile setup --project <ProjectName> --platform <ios|android|both> --auto-device \
  --machine <マシン名> --app-id <bundleID> --app-name "<表示名>"
```

`--auto-device` が既存デバイスを選び（iOS=最新 OS の中で "Pro" 優先・**iPad は除外** / Android=API 最大の AVD）、
`--machine` が未登録なら同時に登録し、machines/apps/runs を同じ論理名で書いて解決まで検証する。
機種を指定したいときだけ `--simulator "<機種名>" --os <version>` / `--avd <avdID>` を明示する。
利用可能なデバイスが **0 台のときだけ** 🧑 停止し、Xcode / Android Studio での導入を依頼する。

### 6. アプリのパス（appPath）と未確定の bundle ID は後から設定する

bundle ID をプレースホルダで続行した場合は、`TestProjects/<ProjectName>/profiles/apps/<projectname>.json` の
`app`(ios/android セクション)を実IDへ差し替えるまでアプリの起動(launch)が失敗することを 🧑 に伝える
(セットアップ・dry-run はプレースホルダのままで完走できる)。ステップ9の完了報告にも「bundle ID 要設定」を
残す。

`appPath` はセットアップでは**聞かない・書かない**（未設定なら `autoInstall` は無効のまま =
インストール済みのアプリをそのまま使う）。自動インストールが必要になったら、後から
`TestProjects/<ProjectName>/profiles/apps/<projectname>.json` の `appPath` をビルド済みアプリ
（ios は `.app`、android は `.apk`）へ向ける。相対パスは **WORK_DIR(そのプロジェクトの
Package.swift があるディレクトリ)基準**・`~` 展開可・絶対パス可。
**ユーザーが自発的にパスを伝えてきた場合のみ書く。別リポジトリを覗いて確定値を書き込まない。**

### 7. VSCode 拡張のインストール

**TOOL_ROOT の拡張を**ビルド・インストールする（外部構成でも拡張は TOOL_ROOT 側から入れる）:

```
cd ../foundation-tester/vscode-ftester && npm install && npm run install-local
```

（clone 構成なら `cd vscode-ftester && ...`。）`install-local` はパッケージ→インストール→到達確認まで
一括で行う。**exit code で成否判定**。

### 7.5 MCP サーバの登録（Claude Code から ft_* ツールを使う）

VSIX とは別の消費面。Claude Code がアプリを直接操作してシナリオを生成するための MCP サーバ
（`ftester-mcp`）を登録する。バイナリは TOOL_ROOT のクローンから毎回ビルドされる（配布はソースビルド前提。
products 未宣言でも `swift build --product ftester-mcp` は暗黙 product として通る）。

- **clone 構成**: TOOL_ROOT ルートの `.mcp.json`（既存・プロジェクトスコープ）がそのまま効く。追加不要。
  Claude Code を**クローンルートで開く**前提（相対 `.build/debug` 依存）。

- **外部パッケージ構成（既定）**: WORK_DIR に `.mcp.json` を書く（**claude CLI 不要**・ただの JSON ファイル）。
  TOOL_ROOT を**絶対パス**で埋める（受け手がどの cwd で開いても解決できる）:

  1. `ABS_TOOL_ROOT=$(cd ../foundation-tester && pwd)` で絶対パスを得る。
  2. WORK_DIR の `.mcp.json` に次の `ftester` サーバを書く（既存 `.mcp.json` があれば
     `mcpServers.ftester` キーは**この TOOL_ROOT の値で上書き**し、他のサーバは温存する。
     既存の `ftester` が**別のパス**を指していたら、上書きした旨と旧パスを 🧑 に報告する —
     旧 clone を残すと clone 先が分裂するため。不要なら削除は getting-started「アンインストール」）。
     `<ABS_TOOL_ROOT>` は 1 の実値に置換（パスに空白があっても壊れないよう引用符は保持）:

```json
{
  "mcpServers": {
    "ftester": {
      "command": "bash",
      "args": ["-lc", "WD=\"$PWD\"; cd \"<ABS_TOOL_ROOT>\" && swift build --product ftester-mcp >/dev/null 2>&1 && cd \"$WD\" && exec \"<ABS_TOOL_ROOT>/.build/debug/ftester-mcp\""],
      "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
    }
  }
}
```

  rebuild-on-start なので `/ftester-update` 後も版ズレしない（無変更なら増分ビルドは即座）。build 出力は
  `/dev/null`（JSON-RPC は stdout 専用・混ぜると壊れる）。`bash -lc`（ログインシェル）はデスクトップ版
  Claude Code が最小 PATH でサーバを起こしても swift/Xcode ツールチェインを引けるようにするため。
  **ビルドのため TOOL_ROOT へ `cd` した後、`exec` 前に元の WORK_DIR へ戻す**（cwd は `ftester-mcp` が
  パッケージルートを特定する入力。cd したままだと外部パッケージ構成で受け手の `TestProjects/` が見えなくなる）。
  `env.FT_TOOL_ROOT` は**ブリッジ資産（`Runner/`・`InAppBridge/`）のルート**の明示指定（cwd が指す
  受け手パッケージ＝`TestProjects/` 側とは別物）。省略しても自動解決するが、明示すると解決に依存しない。
  `<ABS_TOOL_ROOT>` は3箇所とも同じ絶対パス。

「全プロジェクトで使いたい」場合のみ、代わりに user スコープ登録
（`claude mcp add ftester --scope user -- bash -lc '...'`・claude CLI が PATH に要る）を案内する。
CLI が無ければ上の WORK_DIR `.mcp.json` 方式で十分。

**検証ゲート**: **WORK_DIR で** `<ABS_TOOL_ROOT>/.build/debug/ftester doctor --roots-only` が exit 0 で、
**ツール本体 = TOOL_ROOT / シナリオのパッケージ = WORK_DIR** と表示されること（逆・同一なら
`.mcp.json` の値か開く場所が違う）。FM 判定を挟まないので即座に返る。

### 7.6 エージェントの入口を WORK_DIR の CLAUDE.md に置く

**導入直後ではなく、その後のセッションのための手当て**。`.mcp.json` も `.claude/settings.json` も
「設定として効く」だけでエージェントが読む物ではないので、これが無いと翌週
「このアプリのテスト書いて」と言われた Claude Code の手掛かりは**スキルの description だけ**になる。
潰したい実害は3つ ——「素の XCTest を書き始める」「新しい `ft_*` に気づかない」
「DSL コマンドを推測で書く」。

**使い方の解説は書かない**（それは `ft_*` のツール説明と `/ftester-scenario` の仕事。
ここに書くと二重管理になり必ずズレる）。入口の4行だけを、**マーカーの内側だけ**差し替える形で置く
（受け手の既存の記述には触れない。ファイルが無ければ新規作成、マーカーが無ければ末尾に追記）。
**マーカーは説明文を含めない**（文言を変えた瞬間に既存ブロックを見失い二重に追記されるため。
説明は本文側に置く）:

```markdown
<!-- ftester:begin -->
## テスト(foundation-tester)

<!-- この範囲は Scripts/install.sh が管理しており、更新のたび上書きされます。
     不要なら begin〜end ごと削除するか、インストーラに --skip-claude-md を渡してください。 -->

- シナリオ作成は `/ftester-scenario`、対象アプリ/デバイスの追加は `/ftester-profiles`、更新は `/ftester-update`
- 画面の探索・操作は `ft_*` ツール。**長いリストは `ft_swipe` の繰り返しでなく `ft_scroll_to`**
- DSL のコマンド名は推測せず `ft_dsl_commands` で索引を引く(無いコマンドを書かないため)
- シナリオは `TestProjects/<プロジェクト>/scenarios/*.swift`。実行は `ft_run_scenario` か VSCode 拡張
<!-- ftester:end -->
```

**チーム共有リポジトリでツール固有の記述を嫌う受け手には入れない**。インストーラなら
`--skip-claude-md`、手作業ならこのステップを飛ばす（機能には影響しない＝スキルを明示的に
呼べば同じことができる）。既に入れた後で外したくなったら、マーカーごと削除すればよい。

**検証ゲート**: WORK_DIR の `CLAUDE.md` にマーカーが**1組だけ**あり、受け手の既存の記述が
残っていること（2回流しても増えない＝冪等）。

### 8. プロファイル（済んでいなければ /ftester-profiles）

インストーラの結果に **`[ok] プロファイル`** が出ていれば作成済み。**ここは飛ばす**。
`[skip]`（`--machine`/`--app-name` を渡さなかった）や `[warn]`（デバイスが無い等で失敗）のときだけ、
**続けて `/ftester-profiles` を呼ぶ**。その際、**ステップ0で聞いた値（プロジェクト名・アプリ表示名・
アプリID・プラットフォーム）とマシン名をそのまま渡し、聞き直させない**。

**この時点で VSCode の反映操作（Reload Window 等）をユーザーに求めたり、完了したか質問したりしない** —
ここまでユーザーが操作するタイミングは一度も無いので、完了しているはずがない。反映はステップ9で最後にまとめて案内する。

### 9. 🧑 最後に: 反映操作の案内（ここで終了）

すべての機械作業の完了を要約して報告し、**これからユーザーが行う操作**として次を案内して終了する
（「完了しましたか?」のような確認質問でフローを塞がない。問題があれば教えてください、で締める）:

- VSCode で **WORK_DIR** を開く（外部構成: あなたのテストパッケージのフォルダ。clone 構成:
  `foundation-tester` フォルダ）
- `Developer: Reload Window` を実行（インストール・設定だけでは反映されない）
- ftester パネル（Test Explorer / デバイスモニター等）を開く
- （7.5 で `.mcp.json` を書いた場合）Claude Code が **ftester MCP サーバの承認**を求めたら許可する
  → `ft_*` ツールが使え、`/ftester-scenario` が MCP 経由で動く

拡張の設定操作は原則不要（外部パッケージ構成では `ftester init` が `.vscode/settings.json` に
`ftester.binaryPath`・`ftester.project` を生成済み。init が「マージできず未更新」警告を出していた場合のみ
手動設定を案内: `ftester.binaryPath` = `../foundation-tester/.build/debug/ftester` または絶対パス。
clone 構成では既定 `.build/debug/ftester` のままでよい）。プロジェクトが複数あるなら設定
`ftester.project` を `<ProjectName>` にするか、拡張の選択で選ぶことも添える。

案内したら**そこで処理を終了する**。指示にない追加作業を自分の判断で始めない（コミット・push・
別プロファイルやシナリオの追加作成・最適化提案などをこちらから勝手に行わない）。

## 完了後

外部パッケージ構成では、以後の `/ftester-setup`(デバイス定義・アプリパス・動作確認)は `ftester init` が
WORK_DIR に置いた**受け手専用スキル**が担う。更新（新しい修正版が出たとき）は `/ftester-update` を使う
（TOOL_ROOT で git pull → swift build 再ビルド → 依存版を揃える → 拡張再インストール → Reload Window）。
手動手順は docs/userDocs/getting-started_ja.md「更新」。
