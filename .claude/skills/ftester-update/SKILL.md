---
name: ftester-update
description: 既に foundation-tester をセットアップ済みの受け手が、新しい修正版（upstream の更新）を取り込む。git pull → Projects/ と Package.swift の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映（Reload Window）までを検証付きで実行する。「更新して」「最新にして」「アップデートして」「新しい版を取り込んで」等の依頼で使う。初回セットアップは /ftester-setup。
---

# ftester 更新 runbook

セットアップ済みの環境に upstream の修正版を取り込む。初回導入は `/ftester-setup`。
背景・手動手順は docs/getting-started.md の「更新」。

> **この手順書自体が古い可能性がある。** プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` の**スナップショット**から読まれており、`git pull` では更新されない。
> **ステップ0 で TOOL_ROOT が確定したら、`<TOOL_ROOT>/.claude/skills/ftester-update/SKILL.md`
> を読み、内容が違えばそちらを正として以降を進める**(clone 側が唯一の正)。

**構成は setup と同じ2通り。まず判定する(ステップ0):**

- **clone 構成**: foundation-tester クローンの中で直接使う。ツールも Projects も同じ場所。
- **外部パッケージ構成(既定)**: 自分のパッケージ(`ftester init` 済み)が横の `../foundation-tester`
  クローンを SPM 依存として引く。ツール更新は TOOL_ROOT を pull+build し、受け手側は依存を反映して再ビルドする。

用語(setup と共通): **TOOL_ROOT** = foundation-tester クローン(git pull / swift build / 拡張ビルドを
行う場所。CLI は `TOOL_ROOT/.build/debug/ftester`)、**WORK_DIR** = 自分の `Projects/` が住むディレクトリ。
外部構成では TOOL_ROOT = `../foundation-tester`・WORK_DIR = 自分のパッケージ。clone 構成では両者は同一。

## 進め方の原則

- 各ステップは **exit code で成否判定**（パイプで grep に繋がない）。
- **人間チェックポイント（🧑）では停止**する（Reload Window はエージェントでは代行不可）。
- 受け手の資産（`Projects/<自分のプロジェクト>/`）を壊さない。`git pull` が衝突したら
  勝手に解決せず、状況をそのままユーザーに見せて相談する。

## 手順

### 0. 構成の判定と TOOL_ROOT / WORK_DIR の確定

setup のステップ 0.5 と対称。カレントか祖先に `Package.swift` と `Sources/FTScenarioRunner/` の
**両方**があるかで判定する(この2つが揃うのは foundation-tester クローンだけ):

- **両方ある = clone 構成**: TOOL_ROOT = WORK_DIR = そのディレクトリ。ステップ1へ。
- **`Package.swift` はあるが `Sources/FTScenarioRunner/` が無い**: まず中身を確認する。
  **ftester マーカー(`// === ftester projects begin`)も foundation-tester への `.package` 依存も
  無ければ、それは ftester と無関係の Swift パッケージ = 未セットアップ** → 停止して `/ftester-setup` を
  案内する(更新を試みない)。あれば**外部パッケージ構成**: WORK_DIR =
  そのディレクトリ。TOOL_ROOT は WORK_DIR/Package.swift の依存宣言から決める:
  - `.package(path: "<パス>")`（ローカルパス依存・setup 既定）→ その `<パス>` が TOOL_ROOT。
    見つからなければ兄弟 `../foundation-tester` を既定とする。
  - `.package(url: "...", from: "<版>")`（git 依存）→ ローカル clone を pull するのではなく
    **版の付け替え**で更新する(ステップ3の「git 依存」)。
- **`Package.swift` が無い**: カレント直下の `foundation-tester/` を探す（curl でスキルだけ親ワークスペースに
  入れた場合の**旧ネスト配置の救済**。現行の既定は兄弟 `../foundation-tester` で、新規にネスト配置を
  作らない。あれば `cd foundation-tester` で clone 構成扱い）。無ければ**未セットアップ** → 停止して
  `/ftester-setup`（初回導入）を案内する。

以降 `ftester ...` は、clone 構成では `swift run ftester ...`、外部構成では
`TOOL_ROOT/.build/debug/ftester ...`(例 `../foundation-tester/.build/debug/ftester ...`)を指す。

### 1. 取り込み（TOOL_ROOT）

TOOL_ROOT で:

```
git pull
```

- 衝突が出たら停止して報告する。clone 構成では受け手の `Projects/` が git 管理下にあると衝突しやすい
  （その場合は Projects/ を git 管理外か別リポジトリにするよう案内する）。外部構成では `Projects/` は
  WORK_DIR 側なので TOOL_ROOT の pull とは衝突しない。
- 版を固定したい場合は `git checkout <新version>`。

### 2. 再ビルド（TOOL_ROOT）

TOOL_ROOT で:

```
swift build
```

CLI 本体・拡張ランタイム・FTScenarioRunner ソースが更新される。

- 🧑 **macOS/Xcode のベータ世代が変わっていた場合**は、Xcode を同じベータへ揃えてから
  フルリビルドが必要（FoundationModels の ABI 不整合で全バイナリが dyld クラッシュする）。
  クラッシュや dyld エラーが出たらこれを疑い、ユーザーに確認する。

### 3. 受け手側の反映

- **clone 構成**: `swift run ftester project sync`（Projects/ ↔ Package.swift マーカー再整合。
  upstream でプロジェクト構成が変わっても整合させる）。
- **外部パッケージ構成**:
  - `.package(path:)`（ローカルパス依存・既定）: pull 済みソースを SPM が直接見るため、**WORK_DIR で**
    `swift build --product ftester-scenarios-<自分のプロジェクト>` で再ビルドすれば反映される
    （念のため先に `swift package resolve`）。バージョン付け替えは不要。
  - `.package(url: from:)`（git 依存）: WORK_DIR/Package.swift の `from:` を新 version へ上げ、WORK_DIR で
    `swift package update`（または `swift package resolve`）。CLI・拡張も同じ版へ揃える。
  - 受け手の `Projects/` 構成を自分で変えた場合のみ `ftester project sync`（WORK_DIR に対して）。

**版の一致が要る**: CLI と拡張と（git 依存なら）FTScenarioRunner の版を揃える。protocol 契約を跨ぐ更新では
拡張が起動時に `ftester api version` で照合し不一致を警告する（`compatCheck.ts`）。path 依存は pull で
自動的に揃うが、url 依存は付け替え漏れに注意。

### 4. 環境検証（TOOL_ROOT）

```
ftester doctor
```

（clone 構成は `swift run ftester doctor`。）赤が出たら対処してから次へ。

### 5. VSCode 拡張の再インストール（TOOL_ROOT）

```
cd <TOOL_ROOT>/vscode-ftester && npm install && npm run install-local
```

（clone 構成なら `cd vscode-ftester && ...`。）`install-local` はパッケージ→インストール→到達確認まで一括。
**exit code で成否判定**。

### 5.5 MCP 登録テンプレートの更新（旧 `.mcp.json` の cwd 罠を修正）

旧版のセットアップ手順で書かれた `.mcp.json` の `ftester` エントリは、`args` が
`cd "<ABS_TOOL_ROOT>" && swift build --product ftester-mcp >/dev/null 2>&1 && exec "<ABS_TOOL_ROOT>/.build/debug/ftester-mcp"`
の形（**ビルドのため TOOL_ROOT へ `cd` したまま `exec` する**）になっていることがある。この形だと
`ftester-mcp` の cwd が TOOL_ROOT のクローン側に固定されたままになり、`packageRoot()`（cwd から上に
`Package.swift` を探す）が WORK_DIR の受け手パッケージではなくクローン側を見つけてしまい、外部パッケージ
構成で受け手の `Projects/` が見えなくなる（新版のテンプレートは exec 前に元の cwd へ戻る）。

- **WORK_DIR の `.mcp.json`**（外部パッケージ構成のみ。clone 構成は同梱 `.mcp.json` を直接編集しない
  ―― 本体側で管理される）を確認する。`mcpServers.ftester.args` に `swift build --product ftester-mcp`
  を含み、かつ `cd "$WD"`（または `WD=`）を**含まない**なら旧テンプレート。次の形へ書き換える
  （`<ABS_TOOL_ROOT>` は既存値をそのまま使う。他のキーは変更しない）:

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

  `env.FT_TOOL_ROOT`（ブリッジ資産 `Runner/`・`InAppBridge/` のルート＝TOOL_ROOT の明示指定）が
  無い旧エントリは、追加しておく（`<ABS_TOOL_ROOT>` は既存 `args` の値と同じ）。無くても自動解決するが、
  明示しておくと起動経路に依存しない。

- **user スコープ登録**（`claude mcp add ftester --scope user ...` で入れた場合）: `claude mcp list` /
  `claude mcp get ftester` で同じ旧パターン（cd 後 exec 前に戻っていない）が無いか確認する。あれば
  一度 `claude mcp remove ftester --scope user` してから、新テンプレート（上と同じ `WD="$PWD"; cd ... ;
  cd "$WD" && exec ...`）で `claude mcp add ftester --scope user -- bash -lc '...'` を再登録する。
  CLI が PATH に無ければこのステップはスキップし、WORK_DIR `.mcp.json` 方式への案内に留める。
- 書き換え後は 🧑 チェックポイント（次のステップ）で Reload Window すれば反映される
  （登録がそもそも無い場合はこのステップは何もしない ―― MCP 未使用の受け手には無関係）。

### 5.7 Claude Code プラグイン（スキル）の更新

**`git pull` ではスキルは更新されない。** プラグイン経由で導入している場合、スキルは
`~/.claude/plugins/cache/foundation-tester/ftester/<版>/.claude/skills/` のスナップショットから
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

`ftester@foundation-tester` が出れば導入済み。**`Version:` は git commit SHA（先頭12桁）**なので、
TOOL_ROOT の HEAD と突き合わせればキャッシュの鮮度を機械判定できる:

```bash
PV=$(claude plugin list | awk '/ftester@foundation-tester/{f=1} f&&/Version:/{print $2; exit}')
HEAD=$(git -C "<TOOL_ROOT>" rev-parse HEAD)
case "$HEAD" in "$PV"*) echo "最新";; *) echo "古い（要更新）: plugin=$PV head=$HEAD";; esac
```

古ければ**この2つを順に実行する**（マーケットプレイスの再取得とプラグイン本体の更新で、**2つとも要る**）:

```bash
claude plugin marketplace update foundation-tester
claude plugin update ftester@foundation-tester
```

- **順序が重要**: marketplace を先に更新しないと、`plugin update` が古い定義を見る。
- 成功すると `Plugin "ftester" updated from <旧SHA> to <新SHA>` と出る。
  **実行後にもう一度上の突き合わせを行い、HEAD と一致することを検証ゲートにする**
  （「実行した」ではなく「一致した」で判定する）。
- **反映には Claude Code の再起動が要る**（ステップ6の人間チェックポイントに含める）。
  再起動するまで、このセッションで読まれるスキルは古いままである点に注意。
- 版は `plugin.json` に `version` を持たせず **git commit SHA** を使っているので、
  push 済みの変更は上記2コマンドで必ず取り込まれる。

### 6. 🧑 人間チェックポイント（反映）

ユーザーに依頼する（代行不可）:

- VSCode で `Developer: Reload Window`（インストールだけでは旧版のまま動く）。外部構成では **WORK_DIR を
  開いている窓**で行う。`ftester.binaryPath` が TOOL_ROOT の CLI
  （`../foundation-tester/.build/debug/ftester` 等）を指しているか併せて確認。
- デバイスモニター等のパネルは**開き直す**（retainContextWhenHidden で古い HTML が残るため）。
- プラグインを更新した場合（5.7）は **Claude Code の再起動**。更新コマンド自体は 5.7 で代行済みなので、
  ここで依頼するのは再起動だけ（再起動するまでスキルは旧版のまま読まれる）。

### 7. 動作確認

最小の1本を通して回帰がないことを確認する。**WORK_DIR で**:

```
ftester run --project <ProjectName> --profile ios
```

（clone 構成は `swift run ftester run ...`。）
