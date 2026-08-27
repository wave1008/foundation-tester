# Codex

fleetest works with [Codex](https://developers.openai.com/codex) as well as Claude Code. The
runbooks are shared: the same `SKILL.md` files back both agents, and only the thin distribution
adapters differ. Nothing about the CLI, the MCP server or the VS Code extension changes.

## What differs from Claude Code

| | Claude Code | Codex |
|---|---|---|
| Skills directory | `.claude/skills/` | `.agents/skills/` |
| Skill invocation | `/fleetest-setup`, or `/fleetest:fleetest-setup` via the plugin | `$fleetest-setup` (or the `/skills` picker) |
| Instruction file | `CLAUDE.md` | `AGENTS.md` |
| MCP registration | `.mcp.json` (project scope) | `~/.codex/config.toml` (user scope) |
| Per-command approval allowlist | `.claude/settings.json` | none — approvals are governed by `approval_policy` and `sandbox_mode` |

## Installing the skills (plugin — recommended)

```bash
codex plugin marketplace add wave1008/foundation-tester
codex plugin add fleetest@foundation-tester
```

That installs the six skills; typing `$fleetest` lists them. **Installed this way they also update
automatically**: `Scripts/update.sh` runs `marketplace upgrade` → `plugin add` and cross-checks the
result against the clone's HEAD.

The subcommands differ from Claude Code: **`marketplace upgrade`** (not `marketplace update`) and
**`plugin add`** (not `plugin install`/`update`; it is idempotent).

## Installing the skills (copies — where plugins are unavailable)

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

## The sandbox: what it does and does not stop

Codex runs shell commands inside a sandbox. **The MCP server runs outside it**, so this splits
cleanly in two — and the split is the opposite of what you might expect.

**Unaffected — no configuration needed.** Everything through the `ft_*` tools: exploring screens,
authoring scenarios, running them, driving simulators and physical devices. The MCP server is
spawned by Codex as an ordinary child process, verified to keep full filesystem and loopback
access even under `--sandbox read-only`.

**Blocked under any sandbox mode except `danger-full-access`** — the install and update runbooks,
because they run through the shell:

| Command | What happens | Why |
|---|---|---|
| `swift build`, `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM nests its own `sandbox-exec`, which the outer sandbox refuses |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | the mach connection to CoreSimulatorService is blocked |
| `adb` | works | it speaks TCP 5037, which `network_access = true` allows |

**`network_access` and `writable_roots` do not fix the first two.** They are not permission
problems: one is a nested sandbox, the other a mach service. Adding writable roots for
`~/Library/Developer/CoreSimulator` changes nothing.

### What to do

`Scripts/install.sh` (step 7.7) and `Scripts/preflight.sh` (the `codex_sandbox=` line) report which
side of this line you are on. **Neither writes the setting** — a sandbox is your security boundary,
so widening it is your decision, not the installer's. Pick one:

**(a) Elevate only the install and update sessions** — recommended, and narrower:

```bash
codex --sandbox danger-full-access     # run /fleetest-setup or /fleetest-update in this session
```

Everyday work needs no change, because `ft_*` is unaffected.

**(b) Relax it permanently** by setting `sandbox_mode = "danger-full-access"` in
`~/.codex/config.toml`. **Do not append it blindly**: TOML rejects a duplicated key, so a second
`sandbox_mode` makes the whole config invalid. It belongs above the first `[table]`; if the key
already exists, edit it in place.

## Skills

The skills and what they do are the same for both agents — see
[Claude Code Skills](./claude_code_skills.md) for the table, and read `$` for `/` in the
invocation names.

### Link
- [index](../index.md)
