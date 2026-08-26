# Codex

fleetest は Claude Code だけでなく [Codex](https://developers.openai.com/codex) でも使えます。
runbook は共有です — 同じ `SKILL.md` が両方のエージェントを動かし、違うのは薄い配布アダプタだけ。
CLI・MCP サーバ・VS Code 拡張は何も変わりません。

## Claude Code との違い

| | Claude Code | Codex |
|---|---|---|
| スキルの置き場所 | `.claude/skills/` | `.agents/skills/` |
| スキルの呼び出し | `/fleetest-setup` | `$fleetest-setup`(または `/skills` セレクタ) |
| 指示ファイル | `CLAUDE.md` | `AGENTS.md` |
| MCP の登録先 | `.mcp.json`(プロジェクトスコープ) | `~/.codex/config.toml`(ユーザースコープ) |
| コマンド単位の承認許可リスト | `.claude/settings.json` | 無し — 承認は `approval_policy` と `sandbox_mode` で決まる |

## スキルの導入

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --agent codex
```

6本のスキルが `.agents/skills/` に入ります。`--agent` を省くと自動判定です:
`.agents/`・`AGENTS.md`・`~/.codex` があれば Codex、`.claude/`・`CLAUDE.md`・`~/.claude` があれば
Claude Code、両方該当することもあります。

コピーで入れたスキルは `git pull` では更新されません。`Scripts/update.sh` が更新のたびに正典から
写し直し、`✅ Skills: refreshed N copied SKILL.md` と報告します。写した後は**エージェントを
再起動**してください(再起動するまで古い手順書が読まれます)。

## MCP サーバの登録

Codex はプロジェクトスコープの `.mcp.json` を読みません。`~/.codex/config.toml`
(または `$CODEX_HOME/config.toml`)の末尾に次を追記します。`<ABS_TOOL_ROOT>` は
`foundation-tester` クローンの絶対パスに置き換えます:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

`Scripts/install.sh` は、エントリが無いときだけこのブロックを追記します。既にあって別の
クローンを指している場合は**書き換えず**、差し替え用の内容を表示するだけです
(自分が書いていない設定を勝手に書き換えません)。

プロジェクトスコープの `.codex/config.toml` には**書かないでください**。あの層は trusted に
した プロジェクトでしか読まれないため、登録が**黙って効かない**状態になり得ます。

## サンドボックスの設定(必須)

Codex の既定は `sandbox_mode = "workspace-write"` で、**loopback を含む outbound 通信**と
**ワークスペース外への書き込み**を遮断します。fleetest はどちらも使うので、既定のままでは
**デバイスを1台も駆動できません** — in-app ブリッジは loopback 上の HTTP、adb は TCP 5037、
エミュレータは gRPC を使います。外部パッケージ構成ではクローンがワークスペースの**兄弟**に
あるため、`swift build` の書き込み先も外側です。

`Scripts/install.sh` のステップ7.7 と `Scripts/preflight.sh` の `codex_sandbox=` 行が、現在の設定で
足りるかを判定します。**どちらも設定を書きません** — サンドボックスは利用者のセキュリティ境界
であり、緩める判断はツールではなく利用者のものだからです。判定が「不足」と出たら、次を自分で
貼り付けてください:

```toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
writable_roots = [
  "<ABS_TOOL_ROOT>",
  "~/.config/fleetest",
  "~/Library/Developer/CoreSimulator",
  "~/.android",
]
```

outbound を常時開けたくない場合は、fleetest を使うセッションだけ
`codex --sandbox danger-full-access` で起動する方法もあります(常設の緩和より時間的に狭い代わりに、
その間は広くなります)。

## スキル一覧

スキルの内容は両エージェントで同じです。一覧は
[Claude Code スキル](./claude_code_skills_ja.md)を参照し、呼び出し名の `/` を `$` に読み替えてください。

### Link
- [index](../index_ja.md)
