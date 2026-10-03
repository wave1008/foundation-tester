---
name: fleetest-update
description: 既に fleetest をセットアップ済みの受け手が、新しい修正版（upstream の更新）を取り込む。git pull → TestProjects/ と Package.swift の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映（Reload Window）までを検証付きで実行する。「更新して」「最新にして」「アップデートして」「新しい版を取り込んで」等の依頼で使う。初回セットアップは /fleetest-setup。
---

# fleetest 更新 runbook

> **ユーザーへの質問・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


セットアップ済みの環境に upstream の修正版を取り込む。初回導入は `/fleetest-setup`。
背景・手動手順は docs/user-docs/update_ja.md。

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
- **どちらでもない**(state.json が無い = 未導入)→ 停止して `/fleetest-setup` を案内する。
  クローンの場所を利用者が知っているなら、その `Scripts/preflight.sh` を `bash` で実行して
  `layout=external-installed` の `tool_root=` を採ってもよい(**`curl … | bash` で実行しない**。
  **`ls` や `find` で周辺を探し回らない** —— 受け手の個人ディレクトリを覗くことになる)。

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
オプション: `--skip-extension` / `--skip-skills` / `--no-pull` / `--force`。)

**更新が無ければ「✅ Up to date」だけ出して即終了する**(全工程は更新が無くても約30秒かかるため。
判定は update-check.sh)。**前回が途中で失敗した・入れ直したいときだけ `--force`** を付ける。

中で `install.sh` を再実行するので、**git pull・swift build・VSCode 拡張・`.mcp.json` の追従・
検証ゲート・ログ**はそちらの規律がそのまま効く。更新固有の作業として
**`fleetest project sync`(構成を問わず)** を行う（スキルのコピーの更新は install.sh のステップ7.8）。

**外部構成ではクローンのローカル変更を自動で破棄する**(クローンに受け手の資産は無い。
捨てた内容は出力に出る)。**これを人に確認しない** — 残したい場合だけ `--keep-local`。
clone 構成では従来どおり確認が出る。

進行は**各ステップ1行ずつ**出る(数分かかる工程には経過時間が付く)。生ログ(swift build・npm・
vsce)は画面に出ず `<WORK_DIR>/.fleetest/install-*.log` にだけ入り、**場所は開始時と最後の
「Next steps」に出る**。**画面に出た行がすべてなので、ログを grep で漁らない**
(人が全文を見たいと言った場合だけ `--verbose` で再実行するか、そのパスを案内する)。

- **exit 1** → 中断。出力の `[fail]` 行(と `→ SKILL.md step N`)の原因を解決して再実行する。
- **exit 2** → 任意ステップのみ未完(`[warn]`)。CLI は使える。warn の内容だけ手当てする。
- **作業フォルダの `.claude/skills/` へコピーしたスキルは install.sh（ステップ7.8）が正典から
  更新する**（印 `.claude/skills/.fleetest-copied` にある名前だけ。`fleetest-setup` は受け手専用なので
  触らない）。更新・追加・削除があった回は出力にエージェントの再起動案内が出る —— **再起動する
  まで古い手順書が読まれ続ける**。

**以降のステップ1〜5 は「スクリプトが失敗したときの手作業手順」**(成功したなら読み飛ばし、
ステップ6の人間チェックポイントへ)。**スクリプトの出力にある情報を別コマンドで取り直さない**
(構成・TOOL_ROOT は preflight、pull/build/拡張/検証の結果は install.sh の `[ok]` 行にある)。

### 1. 取り込み（TOOL_ROOT）

TOOL_ROOT で `git pull`。衝突が出たら停止して報告する(clone 構成では受け手の `TestProjects/` が
git 管理下にあると衝突しやすい。その場合は TestProjects/ を git 管理外か別リポジトリにするよう案内する)。

**pull が失敗したら「届いていない」を必ず伝える**(0.7 の更新スクリプトは自動で処理する。
ここは手動で進めたときの判断)。原因で扱いが変わる:

- **上流に届かない(オフライン)** … 手元のクローンのまま作業は続けてよい。警告だけ
- **遅れ かつ 進みの両方がある(分岐)** … `git rev-list --count HEAD..origin/<branch>` と
  `origin/<branch>..HEAD` を見て判定する。**分岐したクローンは二度と fast-forward せず、
  以後すべての更新が届かない**。外部構成(TOOL_ROOT ≠ WORK_DIR)なら受け手の資産は
  WORK_DIR 側にあるので `git fetch origin <branch>` のうえ `git reset --hard origin/<branch>`
  で上流へ寄せる。clone 構成では勝手に捨てず、**中止して人に判断を仰ぐ**
- **進みだけ** … 保守者が手元にコミットを持つ通常の状態。取り込むものが無いだけで失敗ではない

**古いクローンのまま「更新できた」と報告しない** —— 旧コードをビルドし直しても表面上は成功に見える。

### 2. 再ビルド（TOOL_ROOT）

TOOL_ROOT で `swift build`。CLI 本体・拡張ランタイム・FTScenarioRunner ソースが更新される。

- 🧑 **macOS/Xcode のベータ世代が変わっていた場合**は、Xcode を同じベータへ揃えてから
  フルリビルドが必要（FoundationModels の ABI 不整合で全バイナリが dyld クラッシュする）。
  クラッシュや dyld エラーが出たらこれを疑い、ユーザーに確認する。

### 3. 受け手側の反映

- **構成を問わず** `fleetest project sync`（TestProjects/ ↔ Package.swift マーカー再整合）を update.sh が行う
  (外部パッケージ構成でも、受け手の Package.swift に書かれたシナリオのパスは pull だけでは直らない)。
- **外部パッケージ構成**の依存の解決:
  - `.package(path:)`（既定）: pull 済みソースを SPM が直接見るため反映済み。シナリオは実行時に
    自動ビルドされる（明示するなら WORK_DIR で `swift build --product fleetest-scenarios-<名>`）。
  - `.package(url: branch: "main")`（git 依存）: WORK_DIR で `swift package update`(main を追従するので
    Package.swift の版を書き換える作業は無い)。

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

### 6. 🧑 人間チェックポイント（反映）

ユーザーに依頼する（代行不可）:

- VSCode で `Developer: Reload Window`（インストールだけでは旧版のまま動く）。外部構成では **WORK_DIR を
  開いている窓**で行う。`fleetest.binaryPath` が TOOL_ROOT の CLI
  （`../foundation-tester/.build/debug/fleetest` 等）を指しているか併せて確認。
- デバイスモニター等のパネルは**開き直す**（retainContextWhenHidden で古い HTML が残るため）。
- スキルのコピーが更新された場合（0.7 の出力に再起動案内が出る）は **エージェントの再起動**
  （再起動するまでスキルは旧版のまま読まれる）。
- **MCP（`ft_*` ツール）を使っている場合も Claude Code の再起動**。`.mcp.json` の
  `swift build --product fleetest-mcp` は**サーバ起動時にしか走らない**ので、既に動いている
  `fleetest-mcp` プロセスは更新前のバイナリのまま応答し続ける。再起動せずに動作確認すると、
  取り込んだはずの修正が効いていないように見える（`ft_*` の挙動だけが古い）。

### 7. 動作確認

最小の1本を通して回帰がないことを確認する。`ft_start_run`(project=`<ProjectName>`, profile=`<実行プロファイル名>`(既定 `ios-run`),
scenario=`["<クラス名>.<メソッド>"]`)で始め、`ft_run_status` で結果を引く(`fleetest run --profile` と同じ実行。
作業フォルダで `swift run fleetest run` を起こすので、更新後のソースでビルドされる)。
