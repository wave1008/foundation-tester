# Other Agents

Nothing at the core of fleetest is agent-specific. The installer only sets up the conventions of
[Claude Code](./claude_code_skills.md), but any other agent (Codex, Cline, Cursor, Copilot, …) can
do the same work once you provide these three things yourself:

| What you need | How to get it | Agent-specific? |
|---|---|---|
| The mechanical work (clone, build, project scaffolding, VS Code extension) | the one-line installer below | no |
| `ft_*` (exploring screens, driving devices, running scenarios) | register `fleetest-mcp` as an MCP server | only the config file format |
| The runbooks | point the agent at the `SKILL.md` files in the clone | only where they live |

The only things you give up are **skill auto-discovery and the entry-point file** — being able to
call `/fleetest-setup` by name, and a `CLAUDE.md` that is read automatically at the start of a
session. The runbooks themselves work fine when you simply say "read this file and follow it".

## 1. Install

Run the same mechanical work in one command, without an agent (idempotent):

```bash
mkdir -p ~/my-app-tests && cd ~/my-app-tests
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
  | bash -s -- --name MyApp --app com.example.myapp
```

The installer also writes the Claude Code artefacts. `.mcp.json` and `CLAUDE.md` can be suppressed
with `--skip-mcp` / `--skip-claude-md`; `.claude/settings.json` (the Bash permission allowlist)
currently cannot — other agents simply ignore it.

Prerequisites, updates and uninstall are covered in
[Getting started](../getting-started.md).

## 2. Register the MCP server

`fleetest-mcp` is a plain stdio MCP server, so **any MCP-capable client can use it**. Follow that
client's own configuration format and give it this launch command (`<ABS_TOOL_ROOT>` is the
absolute path of the `foundation-tester` clone; both occurrences are the same value):

```json
"fleetest": {
  "command": "bash",
  "args": ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

For clients configured in TOML (such as Codex's `~/.codex/config.toml`) the same thing looks like
this:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-lc", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

> **Do not blindly append it.** TOML does not allow a table to be defined twice, so a second
> `[mcp_servers.fleetest]` invalidates the **whole file**. If an entry already exists, edit the
> values in place instead of appending.

The arguments and the tool list are in [MCP server](./mcp_server.md).

## 3. Hand over the runbooks

The canonical runbooks live in the clone at `<TOOL_ROOT>/.claude/skills/<name>/SKILL.md`. They are
written not to depend on any one agent's features, so an agent can simply read one and follow it.

| Runbook | What it does |
|---|---|
| `fleetest-setup` | first install (clone → build → project → verification) |
| `fleetest-update` | pull in a newer version |
| `fleetest-profiles` | create machine / app / run profiles in one pass |
| `fleetest-scenario` | author a test scenario (.swift) |
| `fleetest-mcp` | register only the MCP server |
| `fleetest-remote-setup` | turn another Mac into a runner |

If your agent has a skills mechanism, copy them into its directory:

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh \
  | sh -s -- --dir <your agent's skills directory>
```

Without `--dir` they go to the Claude Code location, `.claude/skills/`. Copied skills are not
updated by `git pull`, so leave updates to `Scripts/update.sh` — it re-copies them from the clone
and reports `✅ Skills: refreshed N copied SKILL.md`. **Restart the agent** afterwards, or it keeps
reading the old runbooks.

## Using Codex (the sandbox)

Codex runs shell commands inside a sandbox, and **the MCP server runs outside it**, so the impact
splits cleanly in two (measured 2026-08-27).

**Unaffected, no configuration needed** — everything through the `ft_*` tools: exploring screens,
authoring and running scenarios, driving simulators and physical devices. Even with
`--sandbox read-only` the server reaches the file system and loopback.

**Blocked unless `danger-full-access`** — the install and update runbooks, because they run through
the shell:

| Command | What happens | Why |
|---|---|---|
| `swift build` / `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM nests its own `sandbox-exec`, which the outer sandbox denies |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | the mach connection to CoreSimulatorService is blocked |
| `adb` | works | it uses TCP 5037, so `network_access = true` is enough |

**Neither of the first two is fixed by `network_access` or `writable_roots`** — they are not
permission problems (one is a nested sandbox, the other a mach service). The narrowest workaround
is to start `codex --sandbox danger-full-access` for the install/update session only. Relaxing it
permanently means setting `sandbox_mode`, which has the same duplicate-key hazard: a second
`sandbox_mode` invalidates the whole `config.toml`.

### Link
- [index](../index.md)
