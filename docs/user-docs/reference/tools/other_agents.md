# AI Assistants Other Than Claude Code

[in Japanese(日本語)](other_agents_ja.md)

Nothing at the core of fleetest is agent-specific. In Claude Code the
[skills](./claude_code_skills.md) can be called by name such as `/fleetest-setup`, but any other agent
(Codex, Cline, Cursor, Copilot, …) can do the same work once you provide these three things:

| What you need | How to get it | Agent-specific? |
|---|---|---|
| The mechanical work (clone, build, project scaffolding, VS Code extension) | the clone and installer below | no |
| `ft_*` (exploring screens, driving devices, running scenarios) | register `fleetest-mcp` as an MCP server | only the config file format |
| The runbooks | point the agent at the `SKILL.md` files in the clone | only where they live |

The only thing you give up is **skill auto-discovery** — being able to call `/fleetest-setup` by
name. The runbooks themselves work fine when you simply say "read this file and follow it". The
installer writes the entry point to `AGENTS.md` in your test folder (with the paths to the runbooks
and to the [agent guide](agent_guide.md)), so an agent that reads `AGENTS.md` picks it up at the start
of a session.

## 1. Install

Open a new, test-only folder in VSCode, start your agent there, and ask it:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

To go through it by hand without an agent, clone the tool and run the same mechanical work with the installer (idempotent):

```bash
mkdir -p ~/my-app-tests && cd ~/my-app-tests
git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester
bash ../foundation-tester/Scripts/install.sh
```

The installer also writes the Claude Code artefacts (`.mcp.json`, `.claude/settings.json`, and
copies of the skills). `.mcp.json` can be suppressed with `--skip-mcp`, and the entry point
(`AGENTS.md`, plus a `CLAUDE.md` that only imports it) with `--skip-entry-point`;
`.claude/settings.json` (the Bash permission allowlist and the rules that make the fleetest clone read-only) currently cannot — other agents simply
ignore it. For any other agent you register the MCP server in step 2 below (the installer never
writes to an agent's global settings).

Prerequisites are covered in [Getting started](../../getting-started.md), updating in
[Update](../../update.md), and uninstalling in [Uninstall](../../uninstall.md).

## 2. Register the MCP server

The easiest way is to ask your AI assistant to "**register the MCP server**". The assistant
registers it with its own CLI (for Codex, the command below; registering the same name again
overwrites it and keeps your other servers). Afterwards, restart the assistant and open a new
session in your test folder.

```bash
codex mcp add fleetest --env FT_TOOL_ROOT=<ABS_TOOL_ROOT> -- bash -c 'exec "<ABS_TOOL_ROOT>/Scripts/mcp-server.sh"'
```

To write the configuration yourself, use the following form.

`fleetest-mcp` is a plain stdio MCP server, so **any MCP-capable client can use it**. Follow that
client's own configuration format and give it this launch command (`<ABS_TOOL_ROOT>` is the
absolute path of the `foundation-tester` clone; both occurrences are the same value):

```json
"fleetest": {
  "command": "bash",
  "args": ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

For clients configured in TOML (such as Codex's `~/.codex/config.toml`) the same thing looks like
this:

```toml
[mcp_servers.fleetest]
command = "bash"
args = ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""]

[mcp_servers.fleetest.env]
FT_TOOL_ROOT = "<ABS_TOOL_ROOT>"
```

Codex asks for approval every time it calls an MCP tool (dozens of times while exploring screens,
and non-interactive `codex exec` rejects them all). The recommended setting **lets calls through without approval
but asks before the real run, `ft_start_run`** ):

```toml
[mcp_servers.fleetest]
default_tools_approval_mode = "approve"

[mcp_servers.fleetest.tools.ft_start_run]
approval_mode = "prompt"
```

Exploring screens and the checks while writing a scenario are not interrupted; you are asked once, when you ask for
a test run. `ft_start_run` runs the run profile's setup / teardown scripts and can send the run to another machine
with `runner`. How to choose what to approve is in [MCP server](./mcp_server.md#sandbox-and-approval).
Non-interactive `codex exec` refuses `prompt` tools, so remove that one table (`[mcp_servers.fleetest.tools.ft_start_run]`)
when you let `codex exec` run tests.

> **Do not blindly append it.** TOML does not allow a table to be defined twice, so a second
> `[mcp_servers.fleetest]` invalidates the **whole file**. If an entry already exists, edit the
> values in place instead of appending.

The arguments and the tool list are in [MCP server](./mcp_server.md).

## 3. Hand over the runbooks

The runbooks live in the clone at `<TOOL_ROOT>/.claude/skills/<name>/SKILL.md`. They are
written not to depend on any one agent's features, so an agent can simply read one and follow it.

| Runbook | What it does |
|---|---|
| `fleetest-setup` | first install (clone → build → project → verification) |
| `fleetest-update` | pull in a newer version |
| `fleetest-profiles` | create app / run profiles in one pass |
| `fleetest-scenario` | author a test scenario (.swift) |
| `fleetest-mcp` | register only the MCP server |
| `fleetest-remote-setup` | turn another Mac into a runner |

The installer copies the runbooks into the work folder's `.claude/skills/` (in Claude Code you call
them by name, such as `/fleetest-scenario`). Other agents should be pointed at the same `SKILL.md`
files through the entry point in the work folder's `AGENTS.md`. Copied skills are not
updated by `git pull`, so leave updates to `Scripts/update.sh` — it re-copies them from the clone
and reports `✅ Skills: refreshed N copied SKILL.md`. **Restart the agent** afterwards, or it keeps
reading the old runbooks.
The installer leaves a marker `.fleetest-copied` in `.claude/skills/`; `update.sh` adds newly
introduced skills **only when the marker exists**.

## Using Codex (the sandbox)

Codex runs shell commands inside a sandbox, and **the MCP server runs outside it**, so the impact
splits cleanly in two.

**Unaffected, no configuration needed** — everything through the `ft_*` tools: exploring screens,
authoring and running scenarios, driving Simulators and physical devices. The real run that keeps result
history and recordings also works through `ft_start_run` (the shell's `fleetest run` does not, for the reasons
below, so have the agent use this). The caveat that the project's code then runs outside the sandbox is in
[MCP server](mcp_server.md#sandbox-and-approval). Even with `--sandbox read-only` the server reaches the file system and loopback.

**Blocked inside the sandbox** — the install and update runbooks, because they run through
the shell:

| Command | What happens | Why |
|---|---|---|
| `swift build` / `swift package` | `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM nests its own `sandbox-exec`, which the outer sandbox denies |
| `xcrun simctl` | `CoreSimulatorService connection became invalid` | the mach connection to CoreSimulatorService is blocked |
| `adb` | works | it uses TCP 5037, so `network_access = true` is enough |

**Neither of the first two is fixed by `network_access` or `writable_roots`** — they are not
permission problems (one is a nested sandbox, the other a mach service). When they fail, Codex
asks whether it can run the command outside the sandbox; allow it and the install or update
carries on (confirmed with Codex in VSCode — no special launch option is needed).

**The default sandbox keeps the fleetest clone read-only.** `workspace-write` cannot write outside the work
folder, so writes to the neighbouring `foundation-tester` are denied both through the editing tool (apply_patch)
and through the shell (`sed -i`, redirection, python). A denied operation turns into a
request to run it outside the sandbox. **Approve that only for the install and update steps (install.sh,
update.sh, `swift build`)**, and decline it when the assistant is trying to change the clone for anything else.
For the same reason, do not add the clone to `writable_roots` and do not start Codex with `danger-full-access`.
The entry point the installer puts in the work folder's `AGENTS.md` also says to treat the clone as read-only,
and Codex follows it by reporting mistakes in the clone instead of fixing them itself.

## Using other AI assistants (Cline, Cursor, Copilot and so on)

fleetest writes no settings for these assistants. What protects the fleetest clone is the behaviour rule in the
`AGENTS.md` entry point (it reaches only assistants that read `AGENTS.md`) and each assistant's own approval
settings (fleetest has not measured how these assistants behave).

- Set the assistant up so that file writes outside the work folder, and commands run there, are never approved automatically
- When the assistant asks to write to the clone, decline unless it is the install or update steps (install.sh, update.sh, `swift build`)
- For an assistant that does not read `AGENTS.md`, copy the contents of the entry-point block (from `<!-- fleetest:begin -->`
  to `<!-- fleetest:end -->`) into that assistant's rules file

### Link
- [index](../../index.md)
