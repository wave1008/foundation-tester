---
name: fleetest-setup
description: fleetest を使いたい受け手を、自分の iOS/Android アプリ向けにシナリオを書いて実行できる状態まで初期セットアップする。未クローンなら clone から行い、ビルド・環境検証・テストパッケージの作成・VSCode 拡張のインストールを、検証ゲートと人間チェックポイント付きで順に実行する。「セットアップして」「使えるようにして」「動かせるようにして」等の初回導入依頼で使う。
---

# fleetest 初期セットアップ runbook

> **ユーザーへの質問・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **スキルの呼び出し記法はエージェントごとに違う**(Claude Code は `/fleetest-setup`)。
> 以下は `/` 形で書くので、別の記法のエージェントではそちらへ読み替える。

受け手を、**自分のアプリのシナリオを書いて実行できる状態**まで導く。
全体像・背景は docs/user-docs/getting-started_ja.md。ここはエージェントが順に実行するための手順書。

**入り方は2通り。ステップ 0.5 で判定する:**

- **外部パッケージ構成(既定・テスト専用の受け手ディレクトリ)**: いま開いているこの
  ディレクトリを fleetest テストパッケージにする。**テストプロジェクト(`TestProjects/<name>/`)は
  この受け手ディレクトリに作られる**(セットアップでは作らず、空の `TestProjects/` だけ置く。プロジェクトと
  プロファイルは後から `/fleetest-profiles` が作る)。foundation-tester は「ツール(CLI・拡張)」として横に
  clone+build するだけで、Projects はここに住む。作成は `fleetest init --no-project`。
- **clone 構成(foundation-tester クローンの中で直接作業する保守者/PoC)**: Projects はクローンの
  `TestProjects/` に作る。作成は `fleetest project create`。

以降、**TOOL_ROOT** = foundation-tester クローン(swift build / doctor / 拡張ビルドを行う場所。CLI は
`TOOL_ROOT/.build/debug/fleetest`)、**WORK_DIR** = `TestProjects/` が住む作業ディレクトリ、と呼ぶ。
外部構成では WORK_DIR = このカレント・TOOL_ROOT = clone 先(**既定は隣の `../foundation-tester`**。
ユーザーが指定すればそのパス)。clone 構成では両者は同一(クローン)。

## 進め方の原則

- **各ステップの後に検証ゲートを通す**（exit code / doctor / 到達確認）。緑になるまで次へ進まない。
- **人間チェックポイント（🧑）では必ず停止して依頼・確認する**。エージェントでは代行できない。
- **セットアップは何も質問しない**(人にしか解決できない阻害を除く)。**人に何かを聞くときは必ず選択ダイアログ（Claude Code なら AskUserQuestion）を使う**。チャットに質問文を書いて
  答えを待たない（テキストで聞くと見落とされ、フローが止まる）。自由入力は Other で受ける。
- **セットアップ値は探索しない**：Bundle ID・App ID・ビルド済み `.app`/`.apk` のパス・
  テスト対象アプリの所在などを、兄弟ディレクトリや別リポジトリを勝手に `find`/`grep` で探索して
  確定してはならない。セットアップはこれらを扱わない（後の `/fleetest-profiles` が人間から得る）。
- **冪等に**：既に済んでいる状態を検出したらスキップする（再実行に強く）。
- 失敗したら握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

## 手順

### 0. 前提の機械判定

**まず状態判定スクリプトを実行する**(構成・既存クローン・環境を1回で判定する。読み取りのみ):

```
bash <SCRIPTS>/preflight.sh
```

**カレント = WORK_DIR 候補**を判定する。**スクリプトは必ずローカルのファイルを実行する** ——
`curl … | bash` のようにネットワークから取ったスクリプトをパイプで実行しない(エージェントの
安全確認に止められ、導入の最初の一歩で進めなくなる)。

**`<SCRIPTS>` = この SKILL.md があるディレクトリの3つ上の `Scripts/`**(`<クローン>/.claude/skills/fleetest-setup/`
→ クローンの根)。この SKILL.md は常にクローンから読むので、**この手順書と同じ版**であり、以降の
ステップで渡す引数が必ず通じる。クローンがまだ無いなら、先に利用者へ clone 先(既定は作業フォルダの隣)を
確認して clone してから、その中の SKILL.md を読み直す。

出力は `key=value` 行 + 判定。**終了コードで分岐する**:

- **0 = ready** → 未導入。導入へ進む(この導入は何も質問しない)。`tool_root_exists=` / `cli_built=` で既存クローンの有無も分かる。
- **2 = installed** → 導入済み。**セットアップを続けない**(下の再実行ガードと同じ扱い)。用途別に案内する。
- **1 = blocked** → 導入不可。**出力の理由行をそのまま 🧑 に見せて対処を依頼する**(理由ごとに対処が違い、
  `xcode_error=` と `xcode_select_path=` から切り分け済みの具体的なコマンドが出る。
  license 未同意なら `sudo xcodebuild -license accept`、CommandLineTools が選択されているなら
  `sudo xcode-select -s /Applications/Xcode.app`)。**自分で原因を推測して別のコマンドを案内しない**。
  sudo や Xcode 導入は代行できない。

以下は同じ判定を手で行う場合の内訳(スクリプトが使えないとき)。

**導入済み判定(再実行ガード)**: カレントに `Package.swift` があり `Sources/FTScenarioRunner/` が
**無い**場合、導入の前に `Package.swift` の**中身**で二分する(ファイルの有無だけで判定しない —
受け手が自分のアプリの既存リポジトリで実行したケースと区別がつかない):

- **fleetest マーカー(`// === fleetest projects begin`)か foundation-tester への `.package` 依存が無い** =
  fleetest と無関係の Swift パッケージ。ここには導入できない(`fleetest init` が拒否する)。**中止**して、
  テスト専用の新規ディレクトリで実行し直すよう 🧑 に案内する。
- **ある** = 外部パッケージ構成が確立済み。このセットアップは**実行済み。ここで中止**し、
  用途別に案内する:
  - ツールの更新 → `/fleetest-update`
  - デバイス・アプリ・実行プロファイルの追加 → `/fleetest-profiles`
  - シナリオの作成 → `/fleetest-scenario`
  - **再インストール**(clone 先の変更・導入のやり直し)→ **まずアンインストールを 🧑 に案内**し、
    完了を確認してから `/fleetest-setup` を再実行する。手順は docs/user-docs/uninstall_ja.md
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

**このセットアップは何も質問しない**(人にしか解決できない阻害 = license 同意・sudo・Xcode 導入などを除く)。
プロジェクト名・bundle ID・プラットフォームは聞かない —— テストプロジェクトとプロファイルは、セットアップの後に
`/fleetest-profiles`(クイックスタート)が作る(プロジェクト名は常に `default`。iOS/Android・アプリID はそこで聞く)。
**clone 先も聞かない**（`tool_root=` を完了報告で伝えれば足りる)。
受け手が別の clone 先を明示した場合だけ、そのパスを TOOL_ROOT にする。

**他リポジトリを勝手に探索して値を埋めない**（バージョン・パスの推測は事故のもと）。
ビルド済み `.app`/`.apk` のパス（`appPath`）も、アプリの表示名・デバイスも、ここでは扱わない。

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
  git ノイズになる)。build / doctor / 拡張ビルドは TOOL_ROOT で、`fleetest init` と
  プロファイル設定は WORK_DIR(カレント)で行う。**カレントに `Package.swift` があってはいけない**
  (`fleetest init` が拒否する。既存 repo の直下ではなく、テスト専用の新規ディレクトリで実行する)。

### 0.7 インストーラで機械作業を一括実行（**まずこれを試す**）

ステップ **0.5・1・2・2.5・3・4・7・7.5・7.6・7.7** はインストーラが一括で行う（冪等。済んだ手順は skip される。
**既存クローンは `git pull --ff-only` で更新してから使う** — ローカル変更があれば
**端末で破棄の可否を尋ね、破棄しないなら中止する**（古いクローンのまま build させないため。
端末が無い＝エージェント実行では尋ねられないので必ず中止 `[fail]` になる。その場合は 🧑 に
`git -C <TOOL_ROOT> stash`（残したい）か `reset --hard`（捨ててよい）を依頼してから再実行する）。
版固定（detached）は触らない）。
**引数は渡さない**（プロジェクト名・bundle ID・プラットフォームはここでは扱わない。**探索もしない**）。

```
bash <SCRIPTS>/install.sh
```

**プロジェクトもプロファイル(アプリ/実行)もインストーラでは作らない**（空の `TestProjects/` だけ置く）——
セットアップの後、クイックスタート(docs/user-docs/quick-start_ja.md。`/fleetest-profiles`)で作る。

- **インストーラが規約位置(`.claude/`・`.mcp.json`)を用意するのは Claude Code だけ**。入口の
  `AGENTS.md` は他のエージェントも読む。他のエージェント(Codex・Cline 等)で使う受け手には、MCP サーバの
  登録と手順書の渡し方を docs/user-docs/reference/tools/other_agents_ja.md で案内する（生成物が不要なら
  `--skip-mcp` / `--skip-entry-point`）。
- **`<SCRIPTS>` の install.sh を使う**(ステップ0と同じ置き場。この手順書と同じ版なので引数が必ず
  通じる。クローンの clone・pull はインストーラが行う)。**`curl … | bash` で実行しない**(ステップ0)。
  `FLEETEST_REF` は**保守者が未マージのブランチを検証するため**の口(clone する ref)で、受け手は何も
  指定しなくてよい(受け手の配布口は main の1本で、版を固定する導線は無い)。
  **ブランチ検証では、そのブランチをチェックアウトしたクローンの SKILL.md を読み、そのクローンの
  `Scripts/` を使う**(未クローンなら `FLEETEST_REF=<ブランチ>` を付けて clone する)—— main の手順書と
  スクリプトでは、直したはずの挙動を確認できない。
  clone 先を変えるなら `--tool-root <dir>`。
- clone 構成（TOOL_ROOT = WORK_DIR）でもそのまま使える（`--work-dir` にクローンを渡す。
  `fleetest init` は走らない。`.mcp.json` はクローンの中に書かれる
  ―― 追跡していないのでクローンは dirty にならない）。

**出力の読み方**（行頭の `[ok]` / `[skip]` / `[warn]` / `[fail]` が機械可読部）:

各ステップは**終わった時点で1行ずつ**出る（数分かかる工程には経過時間が付く）。最後の
「Install results」は**集計と warn/fail の再掲だけ**なので、`[ok]` 行を見たいときは
出力全体から拾う（同じ書式）。`swift build` などの生ログは画面に出ず
`<WORK_DIR>/.fleetest/install-<日時>.log` にある。**ログを grep で漁らない**（必要なら `--verbose`）。

- **exit 0** → 機械作業は完了。**ステップ6へ**。
- **exit 2** → 必須は通ったが任意ステップが未完（`[warn]` 行）。CLI と MCP は使える。
  warn 行が指す**下のステップ番号の手順だけ**を手で通し、原因を直してから同じ引数で再実行する。
- **exit 1** → 必須ステップで停止（`[fail]` 行に「→ SKILL.md step N」が出る）。
  **N の手順を読んで原因を解決し、同じ引数で再実行する**（済んだ手順は skip されるので巻き戻らない）。
  解決に人間の操作が要るもの（Xcode の license 同意・`-runFirstLaunch`・Homebrew 導入）は 🧑 に依頼する。

**以降のステップ1〜4・7・7.5 は「インストーラが失敗したときの手作業手順」**（成功したなら読み飛ばしてよい）。
必ず実施するのは **9（反映操作の案内）** だけ。

**インストーラの出力に載っている情報を、別コマンドで取り直さない**（承認が増えるだけ）:

| 取り直しがちなもの | 既にどこに出ているか |
|---|---|
| TOOL_ROOT の絶対パス（`cd … && pwd`） | preflight の `tool_root=` / インストーラの `[ok] layout` |
| `.mcp.json` の内容（`cat`） | インストーラの `[ok] MCP` |
| `fleetest doctor --roots-only` | インストーラが検証ゲートとして実行済み（`[ok] root-resolution`) |

### 1. xcodegen

`command -v xcodegen` で確認。無ければ `brew install xcodegen`（未導入だと iOS ブリッジ生成が失敗する）。

### 2. ビルド

**TOOL_ROOT で** `swift build`（初回は数分）。**exit code で成否を判定**（パイプで grep に繋がない）。
これで `TOOL_ROOT/.build/debug/fleetest`(CLI 本体)が揃う。以降 `fleetest` はこのバイナリを指す。

### 2.5 Apple Intelligence 自動判定（人間に聞かない・**不可でも続行**）

**TOOL_ROOT で** `swift run fleetest doctor --fm-only` を実行する。これは**実際に1回ずつ推論して**
（テキストと画像入力の2経路）**exit code で返す**（両方使える=0／どちらかでも使えない=1）。
`SystemLanguageModel.default.availability` は `.available` のまま全呼び出しが失敗することがあるので
見ていない。
**FM は必須ではない** — 使うのは FM 視覚検証（`screenLooksLike`・テキストの視覚検証）と、
テストベースからのシナリオ下書き生成（`fleetest draft-scenario`。FM が無ければ決定的な解析に落ちる）
だけで、決定的なシナリオ実行・自己修復（ロケータの指紋照合。FM を使わない）・VSCode 拡張・
MCP のデバイス操作・`/fleetest-scenario` のシナリオ作成・dry-run は FM 無しで動く。**人間に「有効か」を聞かない**：

- **exit 0**（`✅ On-device model: available`）→ 次へ。
- **exit 1**（無効／ダウンロード中／対象外）→ **セットアップは中断せず続行する**。有効化のための
  停止・待機・質問はしない。理由を控えておき、ステップ9の完了報告に
  「Apple Intelligence 要有効化（FM 機能を使う場合）」として残す：後から System 設定 →
  Apple Intelligence & Siri でオンにし、`fleetest doctor --fm-only` が ✅ になれば視覚検証・
  シナリオ生成がそのまま使えるようになる（セットアップのやり直しは不要）。

### 3. 環境検証ゲート

**TOOL_ROOT で** `swift run fleetest doctor` を実行し、出力をユーザーに要約して見せる（FM/AI は 2.5 で判定済み。
**FM の赤はここでも続行してよい** — 2.5 の方針どおり完了報告に残すだけ）。
それ以外の赤（未導入・無効）が残る項目は、ステップ0に戻って人間に対処を依頼してから再実行。次へ。

### 4. テストパッケージを作る(構成で分岐。プロジェクトは作らない)

**WORK_DIR(カレント)で**作る:

- **外部パッケージ構成(既定)**: `fleetest init --no-project` で WORK_DIR を fleetest テストパッケージにする。
  TOOL_ROOT を SPM のローカルパス依存として引く:

```
../foundation-tester/.build/debug/fleetest init --no-project --fleetest-path ../foundation-tester
```

  → WORK_DIR に `Package.swift`(空マーカー区間 + fleetest 依存)と**空の** `TestProjects/`、
  `.vscode/settings.json`(`fleetest.binaryPath`。`fleetest.project` は書かない = 拡張が単一/既定プロジェクトを
  自分で解決する)が生成され、受け手専用の `/fleetest-setup` スキルが `.claude/skills/` に上書きされる
  (次回以降の実行はそちらを使う。この実行はロード済み手順のまま継続してよい)。
  **プロジェクトは作られない** —— セットアップの後、`/fleetest-profiles` が `TestProjects/default/` を作る
  (VSCode 拡張も、`TestProjects/` があって `default` が無ければ起動時に自動で作る)。
  ローカルパス依存なので `swift build` はネットワーク不要・
  TOOL_ROOT を `git pull` すれば fleetest 側も更新される。git 依存にしたい場合のみ `--fleetest-url
  https://github.com/wave1008/foundation-tester.git` を使う(`--fleetest-path` と排他。追従先は `main`。
  **git 依存では `.vscode/settings.json` の `fleetest.binaryPath` が自動設定されない** — CLI・拡張は
  ローカル clone からのビルドが別途必要なので、拡張を使うなら path 依存を推奨し、git 依存を選んだら
  binaryPath の手動設定を 🧑 に案内する)。
  以降このスキル内で `fleetest ...` と書いたら `../foundation-tester/.build/debug/fleetest ...` を実行する。

- **clone 構成**: プロジェクトは作らない(クローンの `TestProjects/` に既にあるものを使う。要るときは
  `/fleetest-profiles` が `swift run fleetest project create default` で作る)。

**検証ゲート(init 後の .gitignore)**: WORK_DIR が git リポジトリ(既存 repo 直下を含む)なら、
`.gitignore` に `.build/` と `TestProjects/*/reports/` があることを確認する(`fleetest init` が自動整備する。
欠けていればこの2行を追記)。`git status` に `.build/` の未追跡ノイズが出ないことまで見る。
何をコミットすべきかを受け手に案内する: `Package.swift`・`Package.resolved`・`TestProjects/`・`.gitignore` は
コミット、`.build/` と `TestProjects/*/reports/` は ignore(init が整備済み)。`.mcp.json` は TOOL_ROOT の
絶対パスを含むためマシン固有。

### 6. プロジェクトとプロファイルは後から作る(質問も設定もしない)

テストプロジェクト(`TestProjects/default/`)・アプリプロファイル(bundle ID・`appPath`)・実行プロファイルは
セットアップでは作らない・聞かない・書かない。ステップ9の案内どおり、`/fleetest-profiles`
(クイックスタート)で iOS/Android とアプリIDを聞いて作る。`appPath` はそこでも**聞かない**
（未設定なら `autoInstall` は無効 = インストール済みのアプリをそのまま使う。後から
`TestProjects/default/profiles/apps/<appRef>.json` の `appPath` をビルド済みアプリ
（ios は `.app`、android は `.apk`。相対パスは WORK_DIR 基準・`~`・絶対可）へ向けられる）。
**ユーザーが自発的にパスを伝えてきた場合のみ書く。別リポジトリを覗いて確定値を書き込まない。**

### 7. VSCode 拡張のインストール

**TOOL_ROOT の拡張を**ビルド・インストールする（外部構成でも拡張は TOOL_ROOT 側から入れる）:

```
cd ../foundation-tester/vscode-fleetest && npm install && npm run install-local
```

（clone 構成なら `cd vscode-fleetest && ...`。）`install-local` はパッケージ→インストール→到達確認まで
一括で行う。**exit code で成否判定**。

install.sh はインストール成功後に、拡張の表示言語 `fleetest.language` を OS の第一言語から決めて
VSCode のユーザー設定へ書く（日本語なら `ja`・それ以外は `en`）。**キーが既にあれば触らない**
（受け手が設定タブで選んだ値を更新で上書きしない）。手で導入した場合は書かれない（既定の `auto`）。

### 7.5 MCP サーバの登録（エージェントから ft_* ツールを使う）

VSIX とは別の消費面。エージェントがアプリを直接操作してシナリオを生成するための MCP サーバ
（`fleetest-mcp`）を登録する。バイナリは TOOL_ROOT のクローンから毎回ビルドされる（配布はソースビルド前提。
products 未宣言でも `swift build --product fleetest-mcp` は暗黙 product として通る）。

- **構成を問わず** WORK_DIR に `.mcp.json` を書く（clone 構成では WORK_DIR = クローン。
  **リポジトリに `.mcp.json` を同梱しない** ―― 中身が絶対パスで、クローンの外では起動しない）。
  以下は書く内容（**claude CLI 不要**・ただの JSON ファイル）。
  TOOL_ROOT を**絶対パス**で埋める（受け手がどの cwd で開いても解決できる）:

  1. `ABS_TOOL_ROOT=$(cd ../foundation-tester && pwd)` で絶対パスを得る。
  2. WORK_DIR の `.mcp.json` に次の `fleetest` サーバを書く（既存 `.mcp.json` があれば
     `mcpServers.fleetest` キーは**この TOOL_ROOT の値で上書き**し、他のサーバは温存する。
     既存の `fleetest` が**別のパス**を指していたら、上書きした旨と旧パスを 🧑 に報告する —
     旧 clone を残すと clone 先が分裂するため。不要なら削除は docs/user-docs/uninstall_ja.md）。
     `<ABS_TOOL_ROOT>` は 1 の実値に置換（パスに空白があっても壊れないよう引用符は保持）:

```json
{
  "mcpServers": {
    "fleetest": {
      "command": "bash",
      "args": ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
      "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
    }
  }
}
```

  起動のたびのビルド・PATH 補正・ログの向き先は `Scripts/mcp-server.sh`（ソースが実行ファイルより
  新しいときだけビルドし直す・build 出力はログファイルへ・stdout は JSON-RPC 専用）に閉じているので、
  ここでは呼び出すだけでよい。**cwd は変えない**（cwd は `fleetest-mcp` がパッケージルートを特定する入力。
  mcp-server.sh はビルドをサブシェルで行い、元の cwd のまま exec する。cwd が変わると外部パッケージ構成で
  受け手の `TestProjects/` が見えなくなる）。
  `env.FT_TOOL_ROOT` は**ブリッジ資産（`Runner/`・`InAppBridge/`）のルート**の明示指定（cwd が指す
  受け手パッケージ＝`TestProjects/` 側とは別物）。省略しても自動解決するが、明示すると解決に依存しない。
  `<ABS_TOOL_ROOT>` は2箇所とも同じ絶対パス。

「全プロジェクトで使いたい」場合のみ、代わりに user スコープ登録
（`claude mcp add fleetest --scope user -- bash -c '...'`・claude CLI が PATH に要る）を案内する。
CLI が無ければ上の WORK_DIR `.mcp.json` 方式で十分。

**検証ゲート**: **WORK_DIR で** `<ABS_TOOL_ROOT>/.build/debug/fleetest doctor --roots-only` が exit 0 で、
**ツール本体 = TOOL_ROOT / シナリオのパッケージ = WORK_DIR** と表示されること（逆・同一なら
`.mcp.json` の値か開く場所が違う）。FM 判定を挟まないので即座に返る。

### 7.6 エージェントの入口を WORK_DIR の AGENTS.md に置く(CLAUDE.md からは読み込むだけ)

**導入直後ではなく、その後のセッションのための手当て**。MCP 登録も `.claude/settings.json` も
「設定として効く」だけでエージェントが読む物ではないので、これが無いと翌週
「このアプリのテスト書いて」と言われたエージェントの手掛かりは**スキルの description だけ**になる。
潰したい実害は3つ ——「素の XCTest を書き始める」「新しい `ft_*` に気づかない」
「DSL コマンドを推測で書く」。

**入口の本文は `AGENTS.md`、`CLAUDE.md` には `@AGENTS.md` の読み込みだけ**を置く。
Claude Code は v2.1.277 から AGENTS.md を読むが、同じ場所か上に CLAUDE.md があると既定では読まず、
古い版は読まない —— CLAUDE.md からの読み込みならどちらにも届き、AGENTS.md を読む他のエージェント
(Codex など)にも同じ本文が届く。

**使い方の解説は書かない**（それは `ft_*` のツール説明と手順書・手引きの仕事。ここに書くと
二重管理になり必ずズレる）。入口の数行だけを、**マーカーの内側だけ**差し替える形で置く
（受け手の既存の記述には触れない。ファイルが無ければ新規作成、マーカーが無ければ末尾に追記）。
**マーカーは説明文を含めない**（文言を変えた瞬間に既存ブロックを見失い二重に追記されるため。
説明は本文側に置く）。`<TOOL_ROOT>` はクローンの絶対パス:

`AGENTS.md`:

```markdown
<!-- fleetest:begin -->
## テスト(fleetest)

<!-- この範囲は Scripts/install.sh が管理しており、更新のたび上書きされます。
     不要なら begin〜end ごと削除するか、インストーラに --skip-entry-point を
     渡してください。 -->

- シナリオ作成・対象アプリ/デバイスの追加・更新は手順書に従う: `<TOOL_ROOT>/.claude/skills/fleetest-scenario/SKILL.md`・`fleetest-profiles/SKILL.md`・`fleetest-update/SKILL.md`(Claude Code ではスキル `/fleetest-scenario` 等として呼べる)
- シナリオを書いて通すまでの短い手引き(英語): `<TOOL_ROOT>/docs/user-docs/reference/tools/agent_guide.md`
- 報告では Simulator・Emulator を「実機」と呼ばない(「実機」は USB でつないだ本物の端末だけ。分からなければ「デバイス」)
- 画面の探索・操作は `ft_*` ツール。**長いリストは `ft_swipe` の繰り返しでなく `ft_scroll_to`**
- DSL のコマンド名は推測せず `ft_dsl_commands` で索引を引く(無いコマンドを書かないため)
- シナリオは `TestProjects/<プロジェクト>/scenarios/*.swift`
- **利用者に実行を頼まれたら `ft_start_run`**(`fleetest run --profile` と同じ実行を裏で始めてすぐ返る。進み具合と結果は `ft_run_status`・止めるのは `ft_stop_run`)。結果の履歴・前回の失敗だけ(`failed`)・全デバイスで1回ずつ(`broadcast`)・録画はこの経路だけ。シェルのサンドボックスの中のエージェントからも動く。`ft_run_scenario` はシナリオを書いている途中の確認用(履歴・録画を残さない)。結果の集計(不安定・遅い・実行ログ)は `ft_results`
<!-- fleetest:end -->
```

`CLAUDE.md`(同じマーカー・同じ管理コメントの下に `@AGENTS.md` の1行だけ):

```markdown
<!-- fleetest:begin -->
<!-- (管理コメントは AGENTS.md と同じ) -->

@AGENTS.md
<!-- fleetest:end -->
```

**チーム共有リポジトリでツール固有の記述を嫌う受け手には入れない**。インストーラなら
`--skip-entry-point`、手作業ならこのステップを飛ばす（機能には影響しない＝スキルや手順書を
明示的に渡せば同じことができる）。既に入れた後で外したくなったら、両方のファイルからマーカーごと
削除すればよい。

**検証ゲート**: WORK_DIR の `AGENTS.md` と `CLAUDE.md` の両方にマーカーが**1組だけ**あり、
受け手の既存の記述が残っていること（2回流しても増えない＝冪等）。

### 7.7 Claude Code 以外のエージェントで使う場合（該当するときだけ）

インストーラが用意するのは Claude Code の規約位置だけ。受け手が Codex・Cline などを使うなら、
`ft_*` を使うには **MCP サーバの登録**が別に要る（登録先はそのクライアントの設定 = 受け手のグローバル設定）。

- **自分の判断で登録しない**。ステップ9の完了報告で「**『MCP を登録して』と頼めば登録する**」と案内し、
  🧑 に頼まれたときだけ登録する（受け手の設定ファイルはセキュリティ境界なので、本人の依頼が条件）。
- 登録は**そのクライアントの CLI で行う**。Codex なら(`<ABS_TOOL_ROOT>` = クローンの絶対パス。2箇所とも同じ値):

  ```
  codex mcp add fleetest --env FT_TOOL_ROOT=<ABS_TOOL_ROOT> -- bash -c 'exec "<ABS_TOOL_ROOT>/Scripts/mcp-server.sh"'
  ```

  同名は上書きされ他のサーバは残る(2回流しても壊れない)。確認は `codex mcp get fleetest`。
  **設定ファイル(`~/.codex/config.toml` 等)を手で編集しない** —— TOML は同じテーブルの重複で
  ファイル全体が無効になる。CLI を持たないクライアントは、書式
  (docs/user-docs/reference/tools/other_agents_ja.md「2. MCP サーバを登録する」)を示して 🧑 に貼ってもらう。
- 登録したら「**AIアシスタントを再起動し、このフォルダで新しいセッションを開く**(再起動後に `ft_*` が使える)」と案内する。
- 手順書の渡し方も同じ docs で案内する。

**Codex を使う受け手への注意**: サンドボックスは**シェルコマンドだけ**を縛る。**MCP サーバは
その外**で動くので、**`ft_*` は既定設定のまま全部動く**（画面探索・シナリオ実行・デバイス駆動）。
通らないのは**シェル経由の導入・更新**だけで、原因は権限ではない:

- `swift build` / `swift package` —— SwiftPM が自前の `sandbox-exec` を入れ子で使うため起動できない
- `xcrun simctl` —— CoreSimulatorService への mach 接続が塞がれる
- **`network_access` や `writable_roots` では直らない**

これらが `Operation not permitted`(`sandbox_apply`)や `CoreSimulatorService connection became invalid` で
失敗したら、**同じコマンドをサンドボックスの外での実行として求める**(承認方式 `on-request` なら 🧑 の許可で通る。
VSCode の Codex の既定で確認)。起動のしかたを変えるよう 🧑 に頼まない。

**検証ゲート**: `ft_list_devices` が候補を返すこと（返らないなら MCP 登録のほう。
サンドボックスは `ft_*` に影響しない）。

### 7.8 スキルを作業フォルダへ置く（Claude Code の `/fleetest-scenario` 等）

インストーラが `<TOOL_ROOT>/.claude/skills/` の正典のうち **`fleetest-setup` 以外**を
`<WORK_DIR>/.claude/skills/` へ**コピー**する（リンクにしない —— 作業フォルダは git にコミットされうる）。
`fleetest-setup` は `fleetest init` が置く受け手専用の別内容なので**絶対に上書きしない**。
置いたスキル名は `<WORK_DIR>/.claude/skills/.fleetest-copied` に1行1つ記録し、**印にある名前だけ**を
以後の実行で更新する（印に無い同名のスキルは受け手のものとして触らない・正典から消えた名前は
写しを消す）。シンボリックリンクは触らない。

次の場合は skip する: `--skip-skills` / WORK_DIR = TOOL_ROOT（クローン構成。正典がそこにある）/
置き先がクローンの git 作業ツリーの内側。**スキルが置かれた・更新された・消えたときは、
エージェントを再起動するまで古い手順書が読まれる**ので、利用者へ再起動を案内する。
Claude Code 以外のエージェントは、このコピーを使わずクローンの SKILL.md を直接読む（ステップ7.7）。

**検証ゲート**: `<WORK_DIR>/.claude/skills/` に `fleetest-scenario` 等が居て、2回流しても結果が変わらないこと。

### 9. 🧑 最後に: 反映操作の案内（ここで終了）

すべての機械作業の完了を要約して報告し、**これからユーザーが行う操作**として次を案内して終了する
（「完了しましたか?」のような確認質問でフローを塞がない。問題があれば教えてください、で締める）:

- VSCode で **WORK_DIR** を開く（外部構成: あなたのテストパッケージのフォルダ。clone 構成:
  `foundation-tester` フォルダ）
- `Developer: Reload Window` を実行（インストール・設定だけでは反映されない）
- 左下のステータスバーの **fleetest mobile** からデバイスモニターを開く
- **Claude Code 以外の AIアシスタント**のときだけ: `ft_*` を使うには MCP サーバの登録が要る。
  「**『MCP を登録して』と頼めば登録します**。登録後は AIアシスタントを再起動して、このフォルダで
  新しいセッションを開いてください」と案内する（ステップ7.7。手で設定する手順を先に並べない）
- **テストプロジェクトとプロファイルの作成はまだ**。続けて `/fleetest-profiles` を実行する
  （iOS/Android とアプリIDを聞いて `TestProjects/default/` とプロファイルを作る）。最初のシナリオ作成は
  `/fleetest-scenario`。流れはクイックスタート(`<TOOL_ROOT>/docs/user-docs/quick-start_ja.md`。
  英語は `quick-start.md`)

**この案内より前に VSCode の反映操作（Reload Window 等）を求めたり、完了したか質問したりしない** ——
ここまでユーザーが操作するタイミングは一度も無い。

拡張の設定操作は原則不要（外部パッケージ構成では `fleetest init` が `.vscode/settings.json` に
`fleetest.binaryPath` を生成済み（`fleetest.project` は書かない。プロジェクトは後から作る）。init が「マージできず未更新」警告を出していた場合のみ
手動設定を案内: `fleetest.binaryPath` = `../foundation-tester/.build/debug/fleetest` または絶対パス。
clone 構成では既定 `.build/debug/fleetest` のままでよい）。プロジェクトが複数あるなら設定
設定 `fleetest.project` で指定するか、拡張の選択で選ぶことも添える。

案内したら**そこで処理を終了する**。指示にない追加作業を自分の判断で始めない（コミット・push・
別プロファイルやシナリオの追加作成・最適化提案などをこちらから勝手に行わない）。

## 完了後

外部パッケージ構成では、以後の `/fleetest-setup`(環境検証・プロジェクトとプロファイルの作成案内・動作確認)は `fleetest init` が
WORK_DIR に置いた**受け手専用スキル**が担う。更新（新しい修正版が出たとき）は `/fleetest-update` を使う
（TOOL_ROOT で git pull → swift build 再ビルド → 依存版を揃える → 拡張再インストール → Reload Window）。
手動手順は docs/user-docs/update_ja.md。
