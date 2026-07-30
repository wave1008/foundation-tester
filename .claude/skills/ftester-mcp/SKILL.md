---
name: ftester-mcp
description: foundation-tester の MCP サーバ(ftester-mcp)だけを Claude Code に登録し、ft_* ツール(アプリを直接操作・スナップショット・シナリオ実行)を使える状態にする。VSCode 拡張・プロジェクト作成・プロファイル設定は行わない。未クローンなら clone → ftester-mcp をビルド → .mcp.json をマージ → 承認案内までを検証付きで実行する。「MCP だけ入れて」「ft_* ツールを使えるようにして」「MCP サーバを登録して」等の依頼で使う。フル導入は /ftester-setup。
---

# ftester MCP 登録 runbook

> **ユーザーへの質問(AskUserQuestion)・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **この手順書が古い可能性がある**: プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` のスナップショットから読まれており `git pull` では更新されない。
> **clone(TOOL_ROOT)が既にあるなら `<TOOL_ROOT>/.claude/skills/ftester-mcp/SKILL.md` を読み、
> 内容が違えばそちらを正とする**。更新は `claude plugin marketplace update foundation-tester` →
> `claude plugin update ftester@foundation-tester`(2つとも要る・Claude Code の再起動で反映)。
> **`/plugin` スラッシュコマンドは VSCode 拡張・Agent SDK 環境では提供されない**ので CLI 形を使う。

Claude Code から `ft_*` ツール(`ft_tap`/`ft_screenshot`/`ft_snapshot`/`ft_run_scenario` 等)を使うための
**MCP サーバ(`ftester-mcp`)だけ**を登録する。VSCode 拡張(.vsix)・`ftester init`(プロジェクト作成)・
プロファイル設定は**やらない**。それらまで含むフル導入は `/ftester-setup`。

MCP サーバのバイナリは TOOL_ROOT のクローンから**起動のたびにビルド**される(配布はソースビルド前提。
rebuild-on-start なので更新後も版ズレしない)。ここは登録に必要な最小手順だけを踏む。

## 進め方の原則

- **各ステップの後に検証ゲート**(exit code / 到達確認)。緑になるまで次へ進まない。
- **人間チェックポイント(🧑)では停止して依頼・確認する**。承認・Reload はエージェントでは代行できない。
- **冪等に**: 既に済んでいる状態(clone 済み・`.mcp.json` の `ftester` が**同じ TOOL_ROOT** を指す)を
  検出したらスキップする。`ftester` キーが**別のパス**を指していたら、スキップせず今回の TOOL_ROOT で
  上書きし、旧パスを 🧑 に報告する(clone 先の分裂防止)。
- 失敗したら握りつぶさず、stderr をそのままユーザーに見せて相談する。
- **探索禁止**: 兄弟ディレクトリや別リポジトリを勝手に `find`/`grep` して値を埋めない。必要な値は人間に聞く。

## 手順

### 0.5 構成判定と TOOL_ROOT の取得

カレントか祖先に `Package.swift` と `Sources/FTScenarioRunner/` の**両方**があるかで判定する
(この2つが揃うのは foundation-tester クローンだけ):

- **両方ある = clone 構成**: いま foundation-tester クローンの中にいる。TOOL_ROOT = WORK_DIR = このディレクトリ。
  この構成では **TOOL_ROOT ルートの `.mcp.json`(リポジトリ同梱・プロジェクトスコープ)がそのまま効く**。
  ステップ2は不要 —— ステップ1(ビルド)と3(人間チェックポイント)だけでよい。

- **無い = 外部パッケージ構成(既定)**: WORK_DIR = このカレント。ツールを供給するため foundation-tester を
  clone する。**clone 先は既定で兄弟ディレクトリ**(受け手ディレクトリの中にネストさせない)。
  ユーザーが clone 先を指定していればそちらへ(以降の `../foundation-tester` はそのパスに読み替える)。
  既にあればスキップ:

```
git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester
```

  → TOOL_ROOT = clone 先(既定 `../foundation-tester`)。以降 `ABS_TOOL_ROOT=$(cd <TOOL_ROOT> && pwd)` で
  **絶対パス**を得ておく(受け手がどの cwd で Claude Code を開いても解決できるように)。

版を固定したい場合は 🧑 に確認して TOOL_ROOT で `git checkout <tag>`。

### 0.7 インストーラで一括実行(**まずこれを試す**)

ステップ1・2とその検証ゲートはインストーラが一括で行う(冪等)。MCP だけ入れるので
**プロジェクト作成と VSCode 拡張は抑止**する:

```
bash <TOOL_ROOT>/Scripts/install.sh --work-dir <WORK_DIR> --skip-project --skip-extension
```

クローンがまだ無ければ clone から:
`curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh | bash -s -- --skip-project --skip-extension`

出力は行頭の `[ok]` / `[skip]` / `[warn]` / `[fail]` で読む。**exit 0 ならステップ3(承認)へ**。
**exit 1 は `[fail]` 行の「→ SKILL.md ステップ N」の手順を手で通して原因を解決し、同じ引数で再実行**
(N は `/ftester-setup` スキルのステップ番号。このスキルのステップ1・2にも同じ内容がある)。
以降のステップ1・2は**インストーラが失敗したときの手作業手順**。

### 1. ftester-mcp をビルド(疎通確認)

**TOOL_ROOT で** `swift build --product ftester-mcp` を実行する(初回は数分。products 未宣言でも暗黙 product
として通る)。**exit code で成否を判定**(パイプで grep に繋がない —— tsc/swift の失敗を握りつぶす事故を避ける)。
これで `TOOL_ROOT/.build/debug/ftester-mcp` が揃い、`.mcp.json` の rebuild-on-start が即座に返るようになる。

失敗したら stderr をそのままユーザーに見せる。よくある原因: Xcode 未導入/版ズレ(macOS ベータ更新後は
Xcode を同ベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で dyld クラッシュする)。

> `ft_*` の頭脳(シナリオ生成・探索)にはオンデバイス FM(Apple Intelligence)が要る。単純なデバイス操作
> (`ft_tap`/`ft_screenshot`/`ft_snapshot`)だけなら不要。FM 可否まで確認したいなら TOOL_ROOT で
> `swift run ftester doctor --fm-only`(可=exit 0 / 不可=1)。ここは MCP 登録の必須ゲートではないので、
> 不可でも登録自体は進めてよい(FM 無効の旨だけ 🧑 に伝える)。

### 2. WORK_DIR に .mcp.json をマージ(外部パッケージ構成のみ)

clone 構成ならこのステップは不要(同梱 `.mcp.json` が効く)。外部構成では **WORK_DIR(カレント)の
`.mcp.json`** に次の `ftester` サーバを書く(**claude CLI 不要**・ただの JSON ファイル)。**既存の `.mcp.json`
があれば `mcpServers.ftester` キーだけをマージし、他サーバは温存する**。`<ABS_TOOL_ROOT>` はステップ0.5 の実値に置換:

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

- `<ABS_TOOL_ROOT>` は**絶対パス**(相対だと開く cwd 次第で解決できない)。3箇所すべて同じ値。
- `env.FT_TOOL_ROOT` は**ブリッジ資産(`Runner/`・`InAppBridge/`)のルート**の明示指定
  (cwd は受け手パッケージ = `Projects/` 側を指すため別物)。省略しても実行ファイルの位置から
  自動解決するが、明示しておくと解決に依存しない。
- build 出力は `/dev/null`(JSON-RPC は stdout 専用・混ぜると壊れる)。
- `bash -lc`(ログインシェル)は、デスクトップ版 Claude Code が最小 PATH でサーバを起こしても
  swift/Xcode ツールチェインを引けるようにするため。
- rebuild-on-start なので `/ftester-update` 後も版ズレしない(無変更なら増分ビルドは即座)。
- **ビルドのため TOOL_ROOT へ `cd` した後、`exec` 前に元の WORK_DIR へ戻す**(`WD="$PWD"; cd ... ;
  cd "$WD"`)。cwd は `ftester-mcp` がパッケージルートを特定する入力(`packageRoot()` の探索基準)。
  cd したまま exec すると外部パッケージ構成で受け手の `Projects/` が見えなくなる。
- cwd = パッケージルートが前提。cd 制御ができない起動経路では代わりに環境変数 `FT_PACKAGE_ROOT`
  でパッケージルートを明示指定できる(未設定なら cwd 探索、無効なパスなら診断のため探索フォールバックせず失敗する)。

「全プロジェクトで使いたい」場合のみ、代わりに user スコープ登録を案内する(claude CLI が PATH に要る):

```
claude mcp add ftester --scope user -e FT_TOOL_ROOT=<ABS_TOOL_ROOT> -- bash -lc 'WD="$PWD"; cd "<ABS_TOOL_ROOT>" && swift build --product ftester-mcp >/dev/null 2>&1 && cd "$WD" && exec "<ABS_TOOL_ROOT>/.build/debug/ftester-mcp"'
```

CLI が無ければ上の WORK_DIR `.mcp.json` 方式で十分。

**検証ゲート**: **WORK_DIR で**(承認前でもここは確認できる)

```
<ABS_TOOL_ROOT>/.build/debug/ftester doctor --roots-only
```

exit 0 で、**ツール本体 = TOOL_ROOT / シナリオのパッケージ = WORK_DIR** と表示されること
(この2つが逆・同一なら `.mcp.json` の値か開く場所が違う)。FM 判定を挟まないので即座に返る。

### 3. 🧑 人間チェックポイント(承認と反映)

エージェントでは代行不可。ユーザーに依頼する:

- Claude Code を **WORK_DIR** で開く(外部構成: このカレント。clone 構成: foundation-tester フォルダ)。
  既に開いているなら **`.mcp.json` を読ませるためウィンドウを再読込**(`Developer: Reload Window`)。
- Claude Code が **ftester MCP サーバの承認**を求めたら**許可する**。
- 承認後、`ft_status` などが応答すれば疎通完了。以後 `ft_tap`/`ft_screenshot`/`ft_snapshot`/`ft_run_scenario`
  等が使え、`/ftester-scenario` も MCP 経由で動く。

疎通しないとき: サーバ起動失敗はたいてい PATH かビルド。TOOL_ROOT で `swift build --product ftester-mcp` が
単体で通るか、`<ABS_TOOL_ROOT>` が絶対パスで正しいかを確認する。

### 4. この先

- テスト対象アプリ・デバイス・実行プロファイルの用意は `/ftester-profiles`。
- シナリオ(.swift)の作成は `/ftester-scenario`。
- VSCode 拡張・プロジェクト作成まで含むフル導入が必要になったら `/ftester-setup`。
