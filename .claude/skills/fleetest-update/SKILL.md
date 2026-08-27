---
name: fleetest-update
description: 既に fleetest をセットアップ済みの受け手が、新しい修正版（upstream の更新）を取り込む。git pull → TestProjects/ と Package.swift の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映（Reload Window）までを検証付きで実行する。「更新して」「最新にして」「アップデートして」「新しい版を取り込んで」等の依頼で使う。初回セットアップは /fleetest-setup。
---

# fleetest 更新 runbook

> **ユーザーへの質問・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


セットアップ済みの環境に upstream の修正版を取り込む。初回導入は `/fleetest-setup`。
背景・手動手順は docs/user-docs/getting-started_ja.md の「更新」。

> **この手順書自体が古い可能性がある。** プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` の**スナップショット**から読まれており、`git pull` では更新されない。
> **ステップ0 で TOOL_ROOT が確定したら、`<TOOL_ROOT>/.claude/skills/fleetest-update/SKILL.md`
> を読み、内容が違えばそちらを正として以降を進める**(clone 側が唯一の正)。

**構成は setup と同じ2通り。まず判定する(ステップ0):**

- **clone 構成**: foundation-tester クローンの中で直接使う。ツールも TestProjects も同じ場所。
- **外部パッケージ構成(既定)**: 自分のパッケージ(`fleetest init` 済み)が横の `../foundation-tester`
  クローンを SPM 依存として引く。ツール更新は TOOL_ROOT を pull+build し、受け手側は依存を反映して再ビルドする。

用語(setup と共通): **TOOL_ROOT** = foundation-tester クローン(git pull / swift build / 拡張ビルドを
行う場所。CLI は `TOOL_ROOT/.build/debug/fleetest`)、**WORK_DIR** = 自分の `TestProjects/` が住むディレクトリ。
外部構成では TOOL_ROOT = `../foundation-tester`・WORK_DIR = 自分のパッケージ。clone 構成では両者は同一。

## 進め方の原則

- 各ステップは **exit code で成否判定**（パイプで grep に繋がない）。
- **人間チェックポイント（🧑）では停止**する（Reload Window はエージェントでは代行不可）。
- 受け手の資産（`TestProjects/<自分のプロジェクト>/`）を壊さない。`git pull` が衝突したら
  勝手に解決せず、状況をそのままユーザーに見せて相談する。

## 手順

### 0. TOOL_ROOT の確定(**まずファイル読み取り。コマンドを打たない**)

`<カレント>/.fleetest/state.json` を**ファイルとして読み**、`toolRoot` を採る(install.sh が導入時に書く)。
読み取りはコマンド実行と違って承認が要らないことが多く、これで**更新フロー全体の承認を
1回(0.7 の update.sh)に抑えられる**。

- `Sources/FTScenarioRunner/` がカレントにある → **clone 構成**。TOOL_ROOT = WORK_DIR = カレント。
- `state.json` があり `toolRoot` が実在 → **外部構成**。WORK_DIR = カレント、TOOL_ROOT = その値。
- **どちらでもない**(state.json が無い = 旧版で導入した、または未導入)→ このときだけ preflight を打つ:

  ```
  curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/preflight.sh | bash
  ```

  `layout=external-installed` なら `tool_root=` を採る。`layout=external-new` は**未導入**なので
  停止して `/fleetest-setup` を案内する。**`ls` や `find` で周辺を探し回らない**
  (受け手の個人ディレクトリを覗くことになるうえ、答えは preflight に出ている)。

### 0.5 更新の有無だけ聞かれた場合(「更新ある?」)

```
bash <TOOL_ROOT>/Scripts/update-check.sh
```

読み取りのみ(fetch もしない)。`verdict=` が `update-available`(exit 3)なら 0.7 へ進む。
`up-to-date`(0)なら**何もせず終える**。`pinned`(0・版固定や git 管理外)と `unknown`(1・オフライン等)は
理由(`reason=`。**英語なので日本語で説明する**)を伝え、勝手に取り込まない。
VSCode 拡張も同じスクリプトを使う(起動時に自動 / コマンド「fleetest: 更新を確認」で手動)。

### 0.7 更新スクリプト(**まずこれを試す**。以降のステップを一括で行う)

```
bash <TOOL_ROOT>/Scripts/update.sh
```

(カレントが WORK_DIR でなければ `--work-dir <WORK_DIR>`。クローンの場所が既定と違うなら `--tool-root <dir>`。
オプション: `--skip-extension` / `--skip-plugin` / `--no-pull` / `--force`。)

**更新が無ければ「✅ Up to date」だけ出して即終了する**(全工程は更新が無くても約30秒かかるため。
判定は update-check.sh)。**前回が途中で失敗した・入れ直したいときだけ `--force`** を付ける。

中で `install.sh` を再実行するので、**git pull・swift build・VSCode 拡張・`.mcp.json` の追従・
検証ゲート・ログ**はそちらの規律がそのまま効く。更新固有の作業として
**`fleetest project sync`(clone 構成)** と **Claude Code プラグインの更新+HEAD との版照合**を行う。

**外部構成ではクローンのローカル変更を自動で破棄する**(クローンに受け手の資産は無い。
捨てた内容は出力に出る)。**これを人に確認しない** — 残したい場合だけ `--keep-local`。
clone 構成では従来どおり確認が出る。

進行は**各ステップ1行ずつ**出る(数分かかる工程には経過時間が付く)。生ログ(swift build・npm・
vsce)は画面に出ず `<WORK_DIR>/.fleetest/install-*.log` にだけ入り、**場所は開始時と最後の
「次にやること」に出る**。**画面に出た行がすべてなので、ログを grep で漁らない**
(人が全文を見たいと言った場合だけ `--verbose` で再実行するか、そのパスを案内する)。

- **exit 1** → 中断。出力の `[fail]` 行(と `→ SKILL.md step N`)の原因を解決して再実行する。
- **exit 2** → 任意ステップのみ未完(`[warn]`)。CLI は使える。warn の内容だけ手当てする。
- プラグインが `⚠️ HEAD と不一致` のときは `claude plugin marketplace update` →
  `claude plugin update` を手で実行する(**順序が重要**。marketplace を先に更新しないと古い定義を見る)。
- **どのエージェントの規約位置を扱うかは前回の導入で固定されている**(`.fleetest/state.json` の
  `agents`。`[ok] agent: ... — pinned by the previous install` と出る)。後からもう一方の
  エージェントを入れた受け手には**そのままでは届かない** —— `bash <TOOL_ROOT>/Scripts/install.sh
  --work-dir <WORK_DIR> --agent auto`(または `--agent both`)で入れ直す。
  preflight の `agents=` 行が今の固定値を出す。
- **コピー配置(`install-skill.sh` で入れた `.claude/skills/` / `.agents/skills/`)は
  update.sh が正典から写し直す**(増えたスキルも置く)(`✅ Skills: refreshed N ...`)。写した後は**エージェントを
  再起動する**まで古い手順書が読まれ続ける。**`fleetest-setup` だけは写さない** ——
  受け手のパッケージのそれは `fleetest init` が生成した受け手専用の別内容なので、
  正典で上書きすると受け手のセットアップ手順が消える。

**以降のステップ1〜5.7 は「スクリプトが失敗したときの手作業手順」**(成功したなら読み飛ばし、
ステップ6の人間チェックポイントへ)。**スクリプトの出力にある情報を別コマンドで取り直さない**
(構成・TOOL_ROOT は preflight、pull/build/拡張/検証の結果は install.sh の `[ok]` 行にある)。

### 1. 取り込み（TOOL_ROOT）

TOOL_ROOT で `git pull`。衝突が出たら停止して報告する(clone 構成では受け手の `TestProjects/` が
git 管理下にあると衝突しやすい。その場合は TestProjects/ を git 管理外か別リポジトリにするよう案内する)。

### 2. 再ビルド（TOOL_ROOT）

TOOL_ROOT で `swift build`。CLI 本体・拡張ランタイム・FTScenarioRunner ソースが更新される。

- 🧑 **macOS/Xcode のベータ世代が変わっていた場合**は、Xcode を同じベータへ揃えてから
  フルリビルドが必要（FoundationModels の ABI 不整合で全バイナリが dyld クラッシュする）。
  クラッシュや dyld エラーが出たらこれを疑い、ユーザーに確認する。

### 3. 受け手側の反映

- **clone 構成**: `fleetest project sync`（TestProjects/ ↔ Package.swift マーカー再整合）。
- **外部パッケージ構成**:
  - `.package(path:)`（既定）: pull 済みソースを SPM が直接見るため反映済み。シナリオは実行時に
    自動ビルドされる（明示するなら WORK_DIR で `swift build --product fleetest-scenarios-<名>`）。
  - `.package(url: from:)`（git 依存）: WORK_DIR/Package.swift の `from:` を新 version へ上げ、
    WORK_DIR で `swift package update`。CLI・拡張も同じ版へ揃える。

**版の一致が要る**: CLI と拡張と（git 依存なら）FTScenarioRunner の版を揃える。protocol 契約を跨ぐ
更新では拡張が起動時に `fleetest api version` で照合し不一致を警告する（`compatCheck.ts`）。

### 4. 環境検証（TOOL_ROOT）

```
fleetest doctor
```

（clone 構成は `swift run fleetest doctor`。）赤が出たら対処してから次へ。

### 5. VSCode 拡張の再インストール（TOOL_ROOT）

```
cd <TOOL_ROOT>/vscode-fleetest && npm install && npm run install-local
```

（clone 構成なら `cd vscode-fleetest && ...`。）`install-local` はパッケージ→インストール→到達確認まで一括。
**exit code で成否判定**。

### 5.5 MCP 登録テンプレートの更新（起動のたびのビルドと、旧 cwd 罠を解消）

旧版のセットアップ手順で書かれた `.mcp.json` の `fleetest` エントリは、`args` にシェル式を
直書きしている（`cd "<ABS_TOOL_ROOT>" && swift build … && exec …`）。この形には実害が3つある:

- **起動のたびに `swift build` が走る**。無変更でも約8秒(実測)かかり、その回に `ft_*` を
  1度も使わなくても必ず払う
- **ビルド出力が `/dev/null`** なので、失敗すると `&&` が切れて**サーバが黙って起動しない**
- さらに古い形（`cd "$WD"` を含まないもの）は **TOOL_ROOT へ cd したまま `exec`** するため、
  `packageRoot()` がクローン側の `Package.swift` を拾い、外部パッケージ構成で受け手の
  `TestProjects/` が見えなくなる

新版はランチャを `Scripts/mcp-server.sh` に切り出してあり、鮮度判定（ソースが実行ファイルより
新しいときだけ建てる）・ログ・失敗時の stderr 出力・cwd の保持をあちらが担う。

- **WORK_DIR の `.mcp.json`**（外部パッケージ構成のみ。clone 構成は同梱 `.mcp.json` を直接編集しない
  ―― 本体側で管理される）を確認する。`mcpServers.fleetest.args` が `swift build` を含むなら
  旧テンプレート。次の形へ書き換える（`<ABS_TOOL_ROOT>` は既存値をそのまま使う。他のキーは変更しない）:

```json
{
  "mcpServers": {
    "fleetest": {
      "command": "bash",
      "args": ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
      "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
    }
  }
}
```

  `env.FT_TOOL_ROOT`（ブリッジ資産 `Runner/`・`InAppBridge/` のルート＝TOOL_ROOT の明示指定）が
  無い旧エントリは、追加しておく（`<ABS_TOOL_ROOT>` は既存 `args` の値と同じ）。無くても自動解決するが、
  明示しておくと起動経路に依存しない。

- **user スコープ登録**（`claude mcp add fleetest --scope user ...` で入れた場合）: `claude mcp list` /
  `claude mcp get fleetest` で同じ旧パターン（cd 後 exec 前に戻っていない）が無いか確認する。あれば
  一度 `claude mcp remove fleetest --scope user` してから、新テンプレート（上と同じ `WD="$PWD"; cd ... ;
  cd "$WD" && exec ...`）で `claude mcp add fleetest --scope user -- bash -lc '...'` を再登録する。
  CLI が PATH に無ければこのステップはスキップし、WORK_DIR `.mcp.json` 方式への案内に留める。
- 書き換え後は 🧑 チェックポイント（次のステップ）で Reload Window すれば反映される
  （登録がそもそも無い場合はこのステップは何もしない ―― MCP 未使用の受け手には無関係）。

### 5.7 Claude Code プラグイン（スキル）の更新

**`git pull` ではスキルは更新されない。** プラグイン経由で導入している場合、スキルは
`~/.claude/plugins/cache/foundation-tester/fleetest/<版>/.claude/skills/` のスナップショットから
読まれており、**自動更新もされない**。ツール本体だけ新しくなり手順書が取り残される
（「更新したのに直らない」の正体）。

**`claude` CLI で代行する**（`/plugin` スラッシュコマンドは **VSCode 拡張・Agent SDK 環境では
提供されず** `/plugin isn't available in this environment.` になる。CLI 形ならどの環境でも動き、
かつエージェントが実行できるので人間チェックポイントにしない）。

まず導入の有無と現在の版を見る（未導入なら以降スキップ。clone 内で直接スキルを使う構成も不要 ――
`git pull` で `.claude/skills/` ごと更新されるため）:

```bash
claude plugin list
```

`fleetest@foundation-tester` が出れば導入済み。**`Version:` は git commit SHA（先頭12桁）**なので、
TOOL_ROOT の HEAD と突き合わせればキャッシュの鮮度を機械判定できる:

```bash
PV=$(claude plugin list | awk '/fleetest@foundation-tester/{f=1} f&&/Version:/{print $2; exit}')
HEAD=$(git -C "<TOOL_ROOT>" rev-parse HEAD)
case "$HEAD" in "$PV"*) echo "最新";; *) echo "古い（要更新）: plugin=$PV head=$HEAD";; esac
```

古ければ**この2つを順に実行する**（マーケットプレイスの再取得とプラグイン本体の更新で、**2つとも要る**）:

```bash
claude plugin marketplace update foundation-tester
claude plugin update fleetest@foundation-tester
```

- **順序が重要**: marketplace を先に更新しないと、`plugin update` が古い定義を見る。
- 成功すると `Plugin "fleetest" updated from <旧SHA> to <新SHA>` と出る。
  **実行後にもう一度上の突き合わせを行い、HEAD と一致することを検証ゲートにする**
  （「実行した」ではなく「一致した」で判定する）。
- **反映には Claude Code の再起動が要る**（ステップ6の人間チェックポイントに含める）。
  再起動するまで、このセッションで読まれるスキルは古いままである点に注意。
- 版は `plugin.json` に `version` を持たせず **git commit SHA** を使っているので、
  push 済みの変更は上記2コマンドで必ず取り込まれる。

### 6. 🧑 人間チェックポイント（反映）

ユーザーに依頼する（代行不可）:

- VSCode で `Developer: Reload Window`（インストールだけでは旧版のまま動く）。外部構成では **WORK_DIR を
  開いている窓**で行う。`fleetest.binaryPath` が TOOL_ROOT の CLI
  （`../foundation-tester/.build/debug/fleetest` 等）を指しているか併せて確認。
- デバイスモニター等のパネルは**開き直す**（retainContextWhenHidden で古い HTML が残るため）。
- プラグインを更新した場合（5.7）は **Claude Code の再起動**。更新コマンド自体は 5.7 で代行済みなので、
  ここで依頼するのは再起動だけ（再起動するまでスキルは旧版のまま読まれる）。
- **MCP（`ft_*` ツール）を使っている場合も Claude Code の再起動**。`.mcp.json` の
  `swift build --product fleetest-mcp` は**サーバ起動時にしか走らない**ので、既に動いている
  `fleetest-mcp` プロセスは更新前のバイナリのまま応答し続ける。再起動せずに動作確認すると、
  取り込んだはずの修正が効いていないように見える（`ft_*` の挙動だけが古い）。

### 7. 動作確認

最小の1本を通して回帰がないことを確認する。**WORK_DIR で**:

```
fleetest run --project <ProjectName> --profile ios
```

（clone 構成は `swift run fleetest run ...`。）
