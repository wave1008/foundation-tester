# Codex

fleetest は Claude Code だけでなく [Codex](https://developers.openai.com/codex) でも使えます。
runbook は共有です — 同じ `SKILL.md` が両方のエージェントを動かし、違うのは薄い配布アダプタだけ。
CLI・MCP サーバ・VS Code 拡張は何も変わりません。

## Claude Code との違い

| | Claude Code | Codex |
|---|---|---|
| スキルの置き場所 | `.claude/skills/` | `.agents/skills/` |
| スキルの呼び出し | `/fleetest-setup`、プラグイン経由なら `/fleetest:fleetest-setup` | `$fleetest-setup`(または `/skills` セレクタ) |
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

## サンドボックスが止めるもの・止めないもの

Codex はシェルコマンドをサンドボックスの中で実行します。**MCP サーバはその外で動く**ので、
影響はきれいに2つに分かれます。分かれ方は直感と逆かもしれません。

**影響なし(設定不要)** — `ft_*` ツール経由の作業すべて。画面の探索・シナリオ作成・実行・
シミュレータや実機の駆動。MCP サーバは Codex が普通の子プロセスとして起動するため、
`--sandbox read-only` を指定した場合でもファイルシステムと loopback に完全にアクセスできることを
実測で確認しています。

**`danger-full-access` 以外では通らない** — 導入・更新の runbook。シェル経由で走るためです:

| コマンド | 何が起きるか | 理由 |
|---|---|---|
| `swift build` / `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM が自前の `sandbox-exec` を入れ子で使い、外側のサンドボックスがそれを拒む |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | CoreSimulatorService への mach 接続が塞がれる |
| `adb` | 通る | TCP 5037 を使うので `network_access = true` で足りる |

**上の2つは `network_access` や `writable_roots` では直りません。** 権限の問題ではないからです
(片方は入れ子のサンドボックス、もう片方は mach サービス)。
`~/Library/Developer/CoreSimulator` を writable_roots に足しても何も変わりません。

### どうするか

`Scripts/install.sh` のステップ7.7 と `Scripts/preflight.sh` の `codex_sandbox=` 行が、
今どちら側にいるかを報告します。**どちらも設定を書きません** — サンドボックスは利用者の
セキュリティ境界であり、緩める判断はツールではなく利用者のものだからです。次のどちらかを選びます。

**(a) 導入・更新のセッションだけ緩める** — 推奨。影響範囲が狭くて済みます:

```bash
codex --sandbox danger-full-access     # このセッションで /fleetest-setup や /fleetest-update を実行
```

`ft_*` は影響を受けないので、日常の作業は既定のままで構いません。

**(b) 恒久的に緩める** — `~/.codex/config.toml` に `sandbox_mode = "danger-full-access"` を設定します。
**そのまま追記しないこと**: TOML は同じキーの重複を許さないので、`sandbox_mode` が2つになると
**config.toml 全体が無効**になります。最初の `[table]` より前に置き、既にあるならその値を編集します。

## スキル一覧

スキルの内容は両エージェントで同じです。一覧は
[Claude Code スキル](./claude_code_skills_ja.md)を参照し、呼び出し名の `/` を `$` に読み替えてください。

### Link
- [index](../index_ja.md)
