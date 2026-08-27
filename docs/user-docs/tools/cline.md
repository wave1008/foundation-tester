# Cline

fleetest works with [Cline](https://cline.bot) as well as Claude Code and Codex. The runbooks are
shared: the same `SKILL.md` files back every agent, and only the thin distribution adapters differ.
The CLI, the MCP server and the VS Code extension are unchanged.

## What differs

| | Claude Code | Codex | Cline |
|---|---|---|---|
| Skills directory | `.claude/skills/` | `.agents/skills/` | `.cline/skills/` |
| Skill invocation | `/fleetest-setup` | `$fleetest-setup` | `/fleetest-setup` |
| Instruction file | `CLAUDE.md` | `AGENTS.md` | `.clinerules` |
| MCP registration | `.mcp.json` (project) | `~/.codex/config.toml` (user) | `~/.cline/mcp.json` (user) |
| Per-command approval allowlist | `.claude/settings.json` | none | none (auto-approve is a different model) |

Cline also reads `.claude/skills/`, so a workspace set up for Claude Code already exposes the
skills. fleetest still installs into `.cline/skills/` — sharing one directory between two agents
creates an implicit coupling, and whichever agent moves its convention first breaks the other one
silently.

## Installing

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --agent cline
```

Then run `/fleetest-setup` in Cline. Without `--agent` the script decides on its own: `.cline/`,
`.clinerules` or `~/.cline` present means Cline, and several agents may apply at once.

## MCP registration

`Scripts/install.sh` writes `~/.cline/mcp.json` — the location Cline documents for its CLI:

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

**The VS Code extension may read its own settings file instead.** If `ft_*` does not appear after a
reload, open the MCP icon in the Cline sidebar, choose *Edit MCP Settings*, and add the same entry
there.

## The instruction file

The installer writes a marked block into `.clinerules`. Cline accepts either a single `.clinerules`
file or a `.clinerules/` folder — when the folder form is in use the block goes to
`.clinerules/fleetest.md` instead. Pass `--skip-clinerules` to opt out; only the marked range is
ever touched.

## Sandboxing

Cline asks for approval per command rather than sandboxing them, so nothing needs relaxing —
unlike Codex, where the default sandbox blocks the install and update runbooks.

### Link
- [index](../index.md)
