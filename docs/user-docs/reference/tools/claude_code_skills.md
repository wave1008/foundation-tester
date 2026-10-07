# Claude Code Skills

fleetest comes with a set of Claude Code skills that automate installation,
profile setup and scenario authoring — each one drives the same underlying scripts and CLI
commands a human would run by hand, with verification gates and human checkpoints where a
decision or an approval genuinely needs a person.

Using a different agent (Codex, Cline, …)? The same runbooks apply — see
[AI assistants other than Claude Code](./other_agents.md) for how to register the MCP server and hand them over.

## Installing the skills

The installer (`install.sh`) copies the skills into the work folder's `.claude/skills/`. You get
them through the steps in [Getting Started](../../getting-started.md) (ask your AI assistant), and
every update refreshes the copies (restart Claude Code after the copies are refreshed). You call
them by name alone, such as `/fleetest-scenario`.

`main` is the only distribution channel — there is no version-pinning route. Pick up fixes
through [Update](../../update.md) or `/fleetest-update`.

## Skills

| Skill | Command | Purpose |
|---|---|---|
| `fleetest-setup` | `/fleetest-setup` | Full initial setup: clone if needed, build, verify the environment, and install the VS Code extension (it creates no test project or profiles; use `fleetest-profiles`) |
| `fleetest-update` | `/fleetest-update` | Pull the latest upstream fixes: git pull, resync `TestProjects/`/`Package.swift`, rebuild, reinstall the VS Code extension, and reload |
| `fleetest-profiles` | `/fleetest-profiles` | Create app and run profiles together in one pass (asks for iOS/Android and the app's display name/ID, then picks or creates a device) |
| `fleetest-scenario` | `/fleetest-scenario` | Author one Swift DSL scenario (`.swift`) in an already set-up project, from live exploration through compile verification |
| `fleetest-mcp` | `/fleetest-mcp` | Register just the MCP server (`fleetest-mcp`) with Claude Code — no VS Code extension, project creation, or profiles |
| `fleetest-remote-setup` | `/fleetest-remote-setup` | Provision another Mac as a runner machine so scenarios can be dispatched to it over SSH |

`fleetest-setup` is the entry point for a first-time install; the others assume it (or an
equivalent manual setup) has already run.

## The `fleetest-scenario` flow

`/fleetest-scenario` walks through:

1. **Confirm the target app** (its app profile) — a human checkpoint.
2. **Provision a device and live-explore it** to collect real selectors from the running app.
3. **Write the scenario** (`.swift`).
4. **Compile-verification gate.**
5. **dry-run gate** — device-free, a few seconds.
6. **Run on a device and confirm it behaves as intended** — a human checkpoint.

Skipping straight from writing to a device run means any error surfaces only after a device-run's
worth of waiting; the compile and dry-run gates catch most mistakes in seconds instead.

## Updating

Use the steps in [Update](../../update.md) (the monitor's "Update now"
button, `/fleetest-update`, or `bash <TOOL_ROOT>/Scripts/update.sh`); it refreshes the skill copies
too. Restart Claude Code afterward for the change to take effect.

### Link
- [index](../../index.md)
