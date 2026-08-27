# その他のエージェント

fleetest の中核は**エージェント固有ではありません**。インストーラが規約位置まで面倒を見るのは
[Claude Code](./claude_code_skills_ja.md) だけですが、それ以外のエージェント(Codex・Cline・
Cursor・Copilot など)でも、次の3つを自分で用意すれば同じことができます。

| 要るもの | 用意の仕方 | エージェント依存 |
|---|---|---|
| 機械作業(clone・ビルド・プロジェクト作成・VSCode 拡張) | 下のインストーラ1コマンド | 無し |
| `ft_*`(画面の探索・操作・シナリオ実行) | `fleetest-mcp` を MCP サーバとして登録 | 設定ファイルの書式だけ |
| 手順書(runbook) | クローンの `SKILL.md`(ツール中立の markdown)を読ませる | 置き場所だけ |

得られないのは**スキルの自動発見と入口ファイル**だけです —— `/fleetest-setup` のように名前で
呼べる仕組みと、セッション冒頭で自動的に読まれる `CLAUDE.md`。手順書は「このファイルを読んで
進めて」と渡せば同じように動きます。

## 1. インストール

エージェントを介さず、同じ機械作業を1コマンドで実行します(冪等):

```bash
mkdir -p ~/my-app-tests && cd ~/my-app-tests
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
  | bash -s -- --name MyApp --app com.example.myapp
```

インストーラは Claude Code 向けの生成物も置きます。`.mcp.json` と `CLAUDE.md` は
`--skip-mcp` / `--skip-claude-md` で抑止できますが、`.claude/settings.json`(Bash 承認の
許可リスト)は現状抑止できません(他のエージェントからは無視されるだけで無害です)。

手順の全体像・前提・アンインストールは
[はじめに(導入・更新・アンインストール)](../getting-started_ja.md)を参照してください。

## 2. MCP サーバを登録する

`fleetest-mcp` は標準の stdio MCP サーバなので、**MCP に対応したクライアントならどれでも**
使えます。設定の書き方は各クライアントに従い、起動コマンドとして次を渡します
(`<ABS_TOOL_ROOT>` は `foundation-tester` クローンの絶対パス。2箇所とも同じ値):

```json
"fleetest": {
  "command": "bash",
  "args": ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

TOML で設定するクライアント(Codex の `~/.codex/config.toml` など)では同じ内容がこの形です:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

> **そのまま追記しないでください。** TOML は同じテーブルの重複を許さないので、
> `[mcp_servers.fleetest]` が2つになると**設定ファイル全体が無効**になります。既にある場合は
> 追記ではなく既存テーブルの値を書き換えてください。

引数と ツールの一覧は [MCP サーバ](./mcp_server_ja.md)にあります。

## 3. 手順書(SKILL.md)を渡す

手順書の正典はクローンの中の `<TOOL_ROOT>/.claude/skills/<name>/SKILL.md` です。特定の
エージェントの機能に依存しないよう書いてあるので、そのまま読ませれば手順どおり進められます。

| 手順書 | 内容 |
|---|---|
| `fleetest-setup` | 初回導入(clone → build → プロジェクト作成 → 検証) |
| `fleetest-update` | 修正版の取り込み |
| `fleetest-profiles` | マシン/アプリ/実行プロファイルの一括作成 |
| `fleetest-scenario` | テストシナリオ(.swift)の作成 |
| `fleetest-mcp` | MCP サーバだけの登録 |
| `fleetest-remote-setup` | 別の Mac をランナー機にする |

スキル機構を持つエージェントなら、その置き場所へコピーできます:

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --dir <そのエージェントのスキルディレクトリ>
```

`--dir` を省くと Claude Code の規約位置 `.claude/skills/` に入ります。コピーしたスキルは
`git pull` では更新されないので、更新は `Scripts/update.sh` に任せます(正典から写し直し、
`✅ Skills: refreshed N copied SKILL.md` と報告します)。写した後は**エージェントを再起動**
してください。

## Codex を使う場合(サンドボックス)

Codex はシェルコマンドをサンドボックスの中で実行します。**MCP サーバはその外で動く**ので、
影響はきれいに2つに分かれます(2026-08-27 に実測)。

**影響なし(設定不要)** — `ft_*` ツール経由の作業すべて。画面の探索・シナリオ作成・実行・
シミュレータや実機の駆動。`--sandbox read-only` でもファイルシステムと loopback に
アクセスできます。

**`danger-full-access` 以外では通らない** — 導入・更新の手順。シェル経由で走るためです:

| コマンド | 何が起きるか | 理由 |
|---|---|---|
| `swift build` / `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM が自前の `sandbox-exec` を入れ子で使い、外側のサンドボックスがそれを拒む |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | CoreSimulatorService への mach 接続が塞がれる |
| `adb` | 通る | TCP 5037 を使うので `network_access = true` で足りる |

**上の2つは `network_access` や `writable_roots` では直りません。** 権限の問題ではないからです
(片方は入れ子のサンドボックス、もう片方は mach サービス)。導入・更新のときだけ
`codex --sandbox danger-full-access` で起動するのが最も狭い回避です(恒久的に緩めるなら
`sandbox_mode` を設定しますが、こちらも**キーの重複で config.toml 全体が無効になる**点に
注意してください)。

### Link
- [index](../index_ja.md)
