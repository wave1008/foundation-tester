---
name: ftester-setup
description: foundation-tester を使いたい受け手を、自分の iOS/Android アプリ向けにシナリオを書いて実行できる状態まで初期セットアップする。未クローンなら clone から行い、ビルド・環境検証・自分のプロジェクト作成・マシン/アプリのプロファイル設定・VSCode 拡張のインストールを、検証ゲートと人間チェックポイント付きで順に実行する。「セットアップして」「使えるようにして」「動かせるようにして」等の初回導入依頼で使う。
---

# ftester 初期セットアップ runbook

> **この手順書が古い可能性がある**: プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` のスナップショットから読まれており `git pull` では更新されない。
> **clone(TOOL_ROOT)が既にあるなら `<TOOL_ROOT>/.claude/skills/ftester-setup/SKILL.md` を読み、
> 内容が違えばそちらを正とする**。更新は `claude plugin marketplace update foundation-tester` →
> `claude plugin update ftester@foundation-tester`(2つとも要る・Claude Code の再起動で反映)。
> **`/plugin` スラッシュコマンドは VSCode 拡張・Agent SDK 環境では提供されない**ので CLI 形を使う。

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
外部構成では WORK_DIR = このカレント・TOOL_ROOT = clone 先(**既定は隣の `../foundation-tester`**。
ユーザーが指定すればそのパス)。clone 構成では両者は同一(クローン)。

## 進め方の原則

- **各ステップの後に検証ゲートを通す**（exit code / doctor / 到達確認）。緑になるまで次へ進まない。
- **人間チェックポイント（🧑）では必ず停止して依頼・確認する**。エージェントでは代行できない。
- **セットアップ値は探索せず人間に聞く**：Bundle ID・App ID・ビルド済み `.app`/`.apk` のパス・
  テスト対象アプリの所在などを、兄弟ディレクトリや別リポジトリを勝手に `find`/`grep` で探索して
  確定してはならない。値は人間から得る（`appPath` のように**聞かない**値は、人間が自発的に示すまで
  未設定のままにする。探索で見つけた候補を既定値として提示するのも避ける）。
  「質問を減らすため」の事前調査も禁止。
- **冪等に**：既に済んでいる状態を検出したらスキップする（再実行に強く）。
- 失敗したら握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

## 手順

### 0. 前提の機械判定と一括質問

**最初に導入済み判定(再実行ガード)**: カレントに `Package.swift` があり `Sources/FTScenarioRunner/` が
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
    完了を確認してから `/ftester-setup` を再実行する。手順は docs/getting-started.md「アンインストール」
    (3層+ WORK_DIR 側の生成物削除。`Projects/` は資産なので残してよい)。アンインストール前に
    セットアップを続行しない。`Package.swift` 等の部分的な書き換えで済まさない(1箇所でも残すと
    旧 clone と新 clone に分裂し、更新が旧側に当たり続ける)

別の clone 先の指定があっても init をやり直さない(`Package.swift` の依存とズレるスプリットブレイン防止)。
clone 構成(両方ある)の再実行は従来どおり冪等スキップで続行してよい。

**環境は機械判定する（人間に「入っているか」を聞かない）**。失敗した項目だけ 🧑 停止して対処を依頼する
（導入・license 同意はエージェントでは代行不可）:

- macOS 26+: `sw_vers -productVersion`（macOS 26 では FM の視覚検証 = occlusion-guard / screenIs
  だけが使えない。画像入力が macOS 27+ のため。中断せず続行し、完了報告にその旨を残す）
- Xcode 26+: `xcodebuild -version`（コマンド自体が license 未同意エラーで落ちたら 🧑 に
  `sudo xcodebuild -license accept` を依頼。sudo は代行不可）
- 初回セットアップ: `xcodebuild -checkFirstLaunchStatus`（exit 0 以外なら 🧑 に `xcodebuild -runFirstLaunch` を依頼）

**セットアップ値は 🧑 に冒頭の1回でまとめて質問する**（以降のステップで散発的に再質問しない）:

- プロジェクト名（英数字 `^[A-Za-z0-9_][A-Za-z0-9_-]*$`）とアプリの bundle ID（→ステップ4で使う。
  **分からなくても中断しない**: 選択肢に「まだ分からない(後で設定)」を含め、その場合は
  プレースホルダ `com.example.myapp` のまま続行する。実IDが要るのは実行(launch)時だけで、
  セットアップ完了後に `profiles/apps/<projectname>.json` の `app` を差し替えれば済む →ステップ6）
- マシン名（→ステップ5で使う）
- ツール（foundation-tester）の clone 先（**任意**。既定は WORK_DIR の隣 `../foundation-tester`。
  AskUserQuestion では「隣（推奨）」を先頭の選択肢にし、任意パスは Other で受ける。
  指定があればそのパスが TOOL_ROOT（→ステップ0.5）。外部パッケージ構成のみ関係）

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
- **無い = 外部パッケージ構成(既定)**: WORK_DIR = このカレント(ここに Projects/ を作る)。
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

ステップ **0.5・1・2・2.5・3・4・7・7.5** はインストーラが一括で行う（冪等。済んだ手順は skip される。
**既存クローンは `git pull --ff-only` で更新してから使う** — ローカル変更があれば
**端末で破棄の可否を尋ね、破棄しないなら中止する**（古いクローンのまま build させないため。
端末が無い＝エージェント実行では尋ねられないので必ず中止 `[fail]` になる。その場合は 🧑 に
`git -C <TOOL_ROOT> stash`（残したい）か `reset --hard`（捨ててよい）を依頼してから再実行する）。
版固定（detached）は触らない）。
ステップ0で聞いた値を引数で渡すだけで、**探索はしない**（appPath・bundle ID を勝手に埋めない設計）。

```
bash <TOOL_ROOT>/Scripts/install.sh --work-dir <WORK_DIR> --name <ProjectName> [--app <bundleID>]
```

- **クローンがまだ無いとき**は clone から丸ごとやる（TOOL_ROOT は既定で WORK_DIR の隣に作られる）:
  `curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh | bash -s -- --name <ProjectName>`
  （clone 先を変えるなら `--tool-root <dir>`。ステップ0で指定があればそれを渡す）
- clone 構成（TOOL_ROOT = WORK_DIR）でもそのまま使える（`--work-dir` にクローンを渡す。
  `ftester init` ではなく `project create` 経路になり、`.mcp.json` は同梱のものが使われる）。

**出力の読み方**（行頭の `[ok]` / `[skip]` / `[warn]` / `[fail]` が機械可読部）:

- **exit 0** → 機械作業は完了。**ステップ5へ**（プロファイルはインストーラの担当外）。
- **exit 2** → 必須は通ったが任意ステップが未完（`[warn]` 行）。CLI と MCP は使える。
  warn 行が指す**下のステップ番号の手順だけ**を手で通し、原因を直してから同じ引数で再実行する。
- **exit 1** → 必須ステップで停止（`[fail]` 行に「→ SKILL.md ステップ N」が出る）。
  **N の手順を読んで原因を解決し、同じ引数で再実行する**（済んだ手順は skip されるので巻き戻らない）。
  解決に人間の操作が要るもの（Xcode の license 同意・`-runFirstLaunch`・Homebrew 導入）は 🧑 に依頼する。

**以降のステップ1〜4・7・7.5 は「インストーラが失敗したときの手作業手順」**（成功したなら読み飛ばしてよい）。
ステップ **5・6・8・9 はインストーラの担当外**なので必ず実施する。

### 1. xcodegen

`command -v xcodegen` で確認。無ければ `brew install xcodegen`（未導入だと iOS ブリッジ生成が失敗する）。

### 2. ビルド

**TOOL_ROOT で** `swift build`（初回は数分）。**exit code で成否を判定**（パイプで grep に繋がない）。
これで `TOOL_ROOT/.build/debug/ftester`(CLI 本体)が揃う。以降 `ftester` はこのバイナリを指す。

### 2.5 Apple Intelligence 自動判定（人間に聞かない・**不可でも続行**）

**TOOL_ROOT で** `swift run ftester doctor --fm-only` を実行する。これは `SystemLanguageModel.default.availability`
（オンデバイス FM／Apple Intelligence の可否）だけを見て **exit code で返す**（可=0／不可=1）。
**FM は必須ではない** — 使うのは heal（自己修復）・FM 視覚検証（`screenIs` 等）・シナリオ生成/探索
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

  → WORK_DIR に `Package.swift`(空マーカー区間 + ftester 依存)と `Projects/<ProjectName>/`、
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
  `Projects/<ProjectName>/` と Package.swift のターゲット登録が生成されたことを確認する。

**検証ゲート(init 後の .gitignore)**: WORK_DIR が git リポジトリ(既存 repo 直下を含む)なら、
`.gitignore` に `.build/` と `Projects/*/reports/` があることを確認する(`ftester init` が自動整備する。
欠けていればこの2行を追記)。`git status` に `.build/` の未追跡ノイズが出ないことまで見る。
何をコミットすべきかを受け手に案内する: `Package.swift`・`Package.resolved`・`Projects/`・`.gitignore` は
コミット、`.build/` と `Projects/*/reports/` は ignore(init が整備済み)。`.mcp.json` は TOOL_ROOT の
絶対パスを含むためマシン固有。

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
{ "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
```

- 利用可能な iOS シミュレータが **0 件のときだけ** 🧑 停止し、Xcode で runtime/デバイスの導入を依頼する。

### 6. アプリのパス（appPath）と未確定の bundle ID は後から設定する

bundle ID をプレースホルダで続行した場合は、`Projects/<ProjectName>/profiles/apps/<projectname>.json` の
`app`(ios/android セクション)を実IDへ差し替えるまでアプリの起動(launch)が失敗することを 🧑 に伝える
(セットアップ・dry-run はプレースホルダのままで完走できる)。ステップ9の完了報告にも「bundle ID 要設定」を
残す。

`appPath` はセットアップでは**聞かない・書かない**（未設定なら `autoInstall` は無効のまま =
インストール済みのアプリをそのまま使う）。自動インストールが必要になったら、後から
`Projects/<ProjectName>/profiles/apps/<projectname>.json` の `appPath` をビルド済みアプリ
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
  パッケージルートを特定する入力。cd したままだと外部パッケージ構成で受け手の `Projects/` が見えなくなる）。
  `env.FT_TOOL_ROOT` は**ブリッジ資産（`Runner/`・`InAppBridge/`）のルート**の明示指定（cwd が指す
  受け手パッケージ＝`Projects/` 側とは別物）。省略しても自動解決するが、明示すると解決に依存しない。
  `<ABS_TOOL_ROOT>` は3箇所とも同じ絶対パス。

「全プロジェクトで使いたい」場合のみ、代わりに user スコープ登録
（`claude mcp add ftester --scope user -- bash -lc '...'`・claude CLI が PATH に要る）を案内する。
CLI が無ければ上の WORK_DIR `.mcp.json` 方式で十分。

**検証ゲート**: **WORK_DIR で** `<ABS_TOOL_ROOT>/.build/debug/ftester doctor --roots-only` が exit 0 で、
**ツール本体 = TOOL_ROOT / シナリオのパッケージ = WORK_DIR** と表示されること（逆・同一なら
`.mcp.json` の値か開く場所が違う）。FM 判定を挟まないので即座に返る。

### 8. 続けてプロファイル一括作成へ（/ftester-profiles）

機械作業が済んだら（1〜7.5）、**続けて `/ftester-profiles` スキルを呼び出す**
（マシン/アプリ/実行プロファイルの一括作成）。**この時点で VSCode の反映操作（Reload Window 等）を
ユーザーに求めたり、完了したか質問したりしない** — ここまでユーザーが操作するタイミングは一度も
無いので、完了しているはずがない。反映はステップ9で最後にまとめて案内する。

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
手動手順は docs/getting-started.md「更新」。
