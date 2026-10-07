# Claude Code 以外の AIアシスタント

[in English](other_agents.md)

fleetest の中核は**エージェント固有ではありません**。Claude Code では
[スキル](./claude_code_skills_ja.md)が `/fleetest-setup` などの名前で呼べますが、それ以外のエージェント
(Codex・Cline・Cursor・Copilot など)でも、次の3つを用意すれば同じことができます。

| 要るもの | 用意の仕方 | エージェント依存 |
|---|---|---|
| 機械作業(clone・ビルド・テストパッケージの用意・VSCode 拡張) | 下の clone とインストーラ | 無し |
| `ft_*`(画面の探索・操作・シナリオ実行) | `fleetest-mcp` を MCP サーバとして登録 | 設定ファイルの書式だけ |
| 手順書(runbook) | クローンの `SKILL.md`(ツール中立の markdown)を読ませる | 置き場所だけ |

得られないのは**スキルの自動発見**だけです —— `/fleetest-setup` のように名前で呼べる仕組み。
手順書は「このファイルを読んで進めて」と渡せば同じように動きます。インストーラはテスト用フォルダの
`AGENTS.md` に入口(手順書と[エージェント向けの手引き](agent_guide_ja.md)の場所)を書くので、
`AGENTS.md` を読むエージェントならセッション冒頭で自動的に読まれます。

## 1. インストール

テスト専用の新規フォルダを VSCode で開き、エージェントを起動して次のように頼みます:

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

エージェントを介さず手で進めたいときは、ツールを clone してから同じ機械作業をインストーラで実行します(冪等):

```bash
mkdir -p ~/my-app-tests && cd ~/my-app-tests
git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester
bash ../foundation-tester/Scripts/install.sh
```

インストーラは Claude Code 向けの生成物(`.mcp.json`・`.claude/settings.json`・スキルの写し)も
置きます。`.mcp.json` は `--skip-mcp` で、入口(`AGENTS.md` と、それを読み込むだけの
`CLAUDE.md`)は `--skip-entry-point` で抑止できますが、`.claude/settings.json`(Bash 承認の
許可リストと、本体のクローンを読み取り専用にする規則)は現状抑止できません(他のエージェントからは無視されるだけで無害です)。
他のエージェントの MCP 登録は、次の「2. MCP サーバを登録する」で行います
(インストーラはエージェントのグローバル設定には書き込みません)。

手順の全体像と前提は[はじめに(インストール)](../../getting-started_ja.md)、更新は[更新](../../update_ja.md)、
アンインストールは[アンインストール](../../uninstall_ja.md)を参照してください。

## 2. MCP サーバを登録する

いちばん簡単なのは、AIアシスタントに「**MCP を登録して**」と頼むことです。AIアシスタントが自分の CLI で
登録します(Codex なら次のコマンド。同じ名前で登録し直すと上書きされ、他のサーバの設定は残ります)。
登録したら AIアシスタントを再起動し、テスト用フォルダで新しいセッションを開いてください。

```bash
codex mcp add fleetest --env FT_TOOL_ROOT=<ABS_TOOL_ROOT> -- bash -c 'exec "<ABS_TOOL_ROOT>/Scripts/mcp-server.sh"'
```

自分で設定ファイルに書く場合は、以下の形です。

`fleetest-mcp` は標準の stdio MCP サーバなので、**MCP に対応したクライアントならどれでも**
使えます。設定の書き方は各クライアントに従い、起動コマンドとして次を渡します
(`<ABS_TOOL_ROOT>` は `foundation-tester` クローンの絶対パス。2箇所とも同じ値):

```json
"fleetest": {
  "command": "bash",
  "args": ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

TOML で設定するクライアント(Codex の `~/.codex/config.toml` など)では同じ内容がこの形です:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

Codex は MCP のツールを呼ぶたびに承認を求めます(画面の探索では数十回になり、非対話の
`codex exec` では全部拒否されます)。おすすめは、**全体は承認なしで通し、本番の実行 `ft_start_run` だけ
承認を求める**設定です):

```toml
[mcp_servers.fleetest]
default_tools_approval_mode = "approve"

[mcp_servers.fleetest.tools.ft_start_run]
approval_mode = "prompt"
```

画面の探索やシナリオ作成中の確認は止まらず、テストの実行を頼んだときにだけ1回聞かれます。
`ft_start_run` は実行プロファイルの setup / teardown スクリプトを動かし、`runner` で別の機械へ送ることも
できるためです。承認を求める範囲の選び方は [MCP サーバ](./mcp_server_ja.md#サンドボックスと承認)にあります。
非対話の `codex exec` では `prompt` のツールは断られるので、`codex exec` で実行まで任せるときは
この1つ(`[mcp_servers.fleetest.tools.ft_start_run]`)を外します。

> **そのまま追記しないでください。** TOML は同じテーブルの重複を許さないので、
> `[mcp_servers.fleetest]` が2つになると**設定ファイル全体が無効**になります。既にある場合は
> 追記ではなく既存テーブルの値を書き換えてください。

引数と ツールの一覧は [MCP サーバ](./mcp_server_ja.md)にあります。

## 3. 手順書(SKILL.md)を渡す

手順書の元になるファイルはクローンの中の `<TOOL_ROOT>/.claude/skills/<name>/SKILL.md` です。特定の
エージェントの機能に依存しないよう書いてあるので、そのまま読ませれば手順どおり進められます。

| 手順書 | 内容 |
|---|---|
| `fleetest-setup` | 初回導入(clone → build → テストパッケージの用意 → 検証。プロジェクトは作らない) |
| `fleetest-update` | 修正版の取り込み |
| `fleetest-profiles` | アプリ/実行プロファイルの一括作成 |
| `fleetest-scenario` | テストシナリオ(.swift)の作成 |
| `fleetest-mcp` | MCP サーバだけの登録 |
| `fleetest-remote-setup` | 別の Mac をランナー機にする |

インストーラは手順書を作業フォルダの `.claude/skills/` へ写します(Claude Code では
`/fleetest-scenario` のように名前で呼べます)。他のエージェントは、作業フォルダの `AGENTS.md` の入口
からたどって同じ `SKILL.md` を読ませてください。写しは `git pull` では更新されないので、更新は
`Scripts/update.sh` に任せます(元のファイルから写し直し、`✅ Skills: refreshed N copied SKILL.md` と
報告します)。写した後は**エージェントを再起動**してください。
インストーラは `.claude/skills/` に印 `.fleetest-copied` を残し、`update.sh` は**この印があるときだけ**
新しく増えたスキルも置きます。

## Codex を使う場合(サンドボックス)

Codex はシェルコマンドをサンドボックスの中で実行します。**MCP サーバはその外で動く**ので、
影響はきれいに2つに分かれます。

**影響なし(設定不要)** — `ft_*` ツール経由の作業すべて。画面の探索・シナリオ作成・実行・
Simulator や実機の駆動。結果の履歴や録画を残す本番の実行も `ft_start_run` で通ります
(シェルの `fleetest run` は下の理由で通らないので、エージェントにはこちらを使わせます)。
サンドボックスの外でプロジェクトのコードが動くことの注意は[MCP サーバ](mcp_server_ja.md#サンドボックスと承認)にあります。`--sandbox read-only` でもファイルシステムと loopback に
アクセスできます。

**サンドボックスの中では通らない** — 導入・更新の手順。シェル経由で走るためです:

| コマンド | 何が起きるか | 理由 |
|---|---|---|
| `swift build` / `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM が自前の `sandbox-exec` を入れ子で使い、外側のサンドボックスがそれを拒む |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | CoreSimulatorService への mach 接続が塞がれる |
| `adb` | 通る | TCP 5037 を使うので `network_access = true` で足りる |

**上の2つは `network_access` や `writable_roots` では直りません。** 権限の問題ではないからです
(片方は入れ子のサンドボックス、もう片方は mach サービス)。Codex はこれらが失敗すると
「サンドボックスの外で実行してよいか」を確認するので、許可すれば導入・更新はそのまま進みます
(VSCode の Codex で確認。起動のしかたを変える必要はありません)。

**fleetest 本体のクローンは、既定のサンドボックスで読み取り専用に保たれます。** `workspace-write` では
作業フォルダの外へ書けないので、隣の `foundation-tester` への書き込みは、編集ツール(apply_patch)も
シェル(`sed -i`・リダイレクト・python)も拒否されます。拒否された操作は
「サンドボックスの外で実行してよいか」の確認になります。**許可するのは導入・更新の手順(install.sh・update.sh・
`swift build`)だけにしてください。** それ以外でクローンを書き換えようとしていたら断ります。
同じ理由で、クローンを `writable_roots` に足したり、`danger-full-access` で起動したりしないでください。
インストーラが作業フォルダの `AGENTS.md` に置く入口にも「クローンは読み取り専用として扱う」と書いてあり、
Codex はこれに従って、クローンの誤りを自分で直さずに報告します。

## その他の AIアシスタントを使う場合(Cline・Cursor・Copilot など)

これらの AIアシスタントには、fleetest は設定を書きません。本体のクローンを守るのは、入口の `AGENTS.md` の
行動ルール(`AGENTS.md` を読むアシスタントにだけ届きます)と、各アシスタントの承認の設定です
(fleetest ではこれらのアシスタントでの挙動を確認していません)。

- 作業フォルダの外へのファイルの書き込みと、そこでのコマンドの実行を、自動で承認しない設定にしてください
- クローンへの書き込みを求められたら、導入・更新の手順(install.sh・update.sh・`swift build`)以外は断ってください
- `AGENTS.md` を読まないアシスタントでは、入口ブロック(`<!-- fleetest:begin -->` から `<!-- fleetest:end -->` まで)の
  内容を、そのアシスタントのルールファイルに写してください

### Link
- [index](../../index_ja.md)
