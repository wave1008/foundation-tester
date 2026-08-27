# Cline

fleetest は Claude Code・Codex に加えて [Cline](https://cline.bot) でも使えます。runbook は共有で、
同じ `SKILL.md` がすべてのエージェントを動かします。違うのは薄い配布アダプタだけで、
CLI・MCP サーバ・VS Code 拡張は何も変わりません。

## 違い

| | Claude Code | Codex | Cline |
|---|---|---|---|
| スキルの置き場所 | `.claude/skills/` | `.agents/skills/` | `.cline/skills/` |
| スキルの呼び出し | `/fleetest-setup` | `$fleetest-setup` | `/fleetest-setup` |
| 指示ファイル | `CLAUDE.md` | `AGENTS.md` | `.clinerules` |
| MCP の登録先 | `.mcp.json`(プロジェクト) | `~/.codex/config.toml`(ユーザー) | `~/.cline/mcp.json`(ユーザー) |
| コマンド単位の承認許可リスト | `.claude/settings.json` | 無し | 無し(auto-approve は別系統) |

Cline は `.claude/skills/` も読むので、Claude Code 用に整えたワークスペースならスキルはすでに
見えています。それでも fleetest は `.cline/skills/` へ入れます —— 1つのディレクトリを2つの
エージェントで共有すると暗黙の結合ができ、**どちらかが規約を変えた瞬間にもう片方が黙って壊れる**
からです。

## 導入

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --agent cline
```

あとは Cline で `/fleetest-setup` を実行します。`--agent` を省くと自動判定です
(`.cline/`・`.clinerules`・`~/.cline` があれば Cline。複数該当することもあります)。

## MCP の登録

`Scripts/install.sh` が `~/.cline/mcp.json` を書きます(Cline が CLI 向けに明記している場所):

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

**VS Code 拡張は自前の設定ファイルを見ることがあります。** 再読込しても `ft_*` が出てこない場合は、
Cline サイドバーの MCP アイコン →「Edit MCP Settings」で同じ内容を追加してください。

## 指示ファイル

インストーラは `.clinerules` にマーカー付きのブロックを書きます。Cline は `.clinerules` 単体ファイルでも
`.clinerules/` フォルダでも読むので、**フォルダ形で運用している場合は `.clinerules/fleetest.md`** へ
書き先が変わります。不要なら `--skip-clinerules`。触るのはマーカーの内側だけです。

## サンドボックス

Cline はコマンドごとに承認を求める方式で、サンドボックスで囲みません。したがって緩める設定は不要です
(既定のサンドボックスが導入・更新の runbook を止める Codex とはここが違います)。

### Link
- [index](../index_ja.md)
