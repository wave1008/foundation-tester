# Codex

fleetest works with [Codex](https://developers.openai.com/codex) as well as Claude Code. The
runbooks are shared: the same `SKILL.md` files back both agents, and only the thin distribution
adapters differ. Nothing about the CLI, the MCP server or the VS Code extension changes.

## What differs from Claude Code

| | Claude Code | Codex |
|---|---|---|
| Skills directory | `.claude/skills/` | `.agents/skills/` |
| Skill invocation | `/fleetest-setup` | `$fleetest-setup` (or the `/skills` picker) |
| Instruction file | `CLAUDE.md` | `AGENTS.md` |
| MCP registration | `.mcp.json` (project scope) | `~/.codex/config.toml` (user scope) |
| Per-command approval allowlist | `.claude/settings.json` | none — approvals are governed by `approval_policy` and `sandbox_mode` |

## Installing the skills

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --agent codex
```

This copies the six skills into `.agents/skills/`. Without `--agent`, the script decides on its
own: `.agents/`, `AGENTS.md` or `~/.codex` present means Codex, `.claude/`, `CLAUDE.md` or
`~/.claude` means Claude Code, and both may apply at once.

Copied skills do not follow `git pull`. `Scripts/update.sh` copies the canonical files over them
again on every update, and reports `✅ Skills: refreshed N copied SKILL.md`; restart the agent
afterwards so the refreshed runbooks are read.

## Registering the MCP server

Codex does not read a project-scoped `.mcp.json`. Append this to `~/.codex/config.toml`
(or `$CODEX_HOME/config.toml`), replacing `<ABS_TOOL_ROOT>` with the absolute path of your
`foundation-tester` clone:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

`Scripts/install.sh` appends exactly this block when the entry is absent. If an entry already
exists and points at a different clone, the installer leaves it alone and prints the replacement
for you to paste — it never rewrites a config it did not write.

Do not put this in a project-scoped `.codex/config.toml`: those layers are only read for projects
you have marked trusted, so the registration can silently do nothing.

## Sandbox settings (required)

Codex defaults to `sandbox_mode = "workspace-write"`, which blocks **all outbound network access
including loopback** and **writes outside the workspace**. fleetest needs both, so with the
default settings it cannot drive a single device: the in-app bridge speaks HTTP over loopback,
adb uses TCP 5037, and the emulator uses gRPC. In the external-package layout the clone is a
*sibling* of your workspace, so even `swift build` writes outside it.

`Scripts/install.sh` (step 7.7) and `Scripts/preflight.sh` (the `codex_sandbox=` line) report
whether the current settings suffice. **Neither writes the settings** — a sandbox is your security
boundary, so widening it is your decision, not the installer's. When the verdict says the settings
are insufficient, edit the file to end up with the following. **Do not append it blindly**: TOML
rejects a duplicated key or table, so a second `sandbox_mode` or `[sandbox_workspace_write]` makes
the whole config invalid. `sandbox_mode` belongs above the first `[table]`, and if
`[sandbox_workspace_write]` already exists, edit the values inside it:

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

If you would rather not leave outbound access open, start Codex with
`codex --sandbox danger-full-access` for the sessions where you use fleetest instead. That is
narrower in time than a permanent change, though wider while it lasts.

## Skills

The skills and what they do are the same for both agents — see
[Claude Code Skills](./claude_code_skills.md) for the table, and read `$` for `/` in the
invocation names.

### Link
- [index](../index.md)
