# Claude Code Skills

The foundation-tester plugin packages a set of Claude Code skills that automate installation,
profile setup and scenario authoring — each one drives the same underlying scripts and CLI
commands a human would run by hand, with verification gates and human checkpoints where a
decision or an approval genuinely needs a person.

## Installing the plugin

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin install ftester@foundation-tester --scope user
```

To pin a version instead of tracking `main`, add the marketplace from a tagged URL:

```bash
claude plugin marketplace add https://github.com/wave1008/foundation-tester.git#<tag>
```

In an environment without a plugin mechanism, an equivalent set of skills can be installed
directly:

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
```

## Skills

| Skill | Command | Purpose |
|---|---|---|
| `ftester-setup` | `/ftester:ftester-setup` | Full initial setup: clone if needed, build, verify the environment, create your project, set up machine/app profiles, and install the VS Code extension |
| `ftester-update` | `/ftester:ftester-update` | Pull the latest upstream fixes: git pull, resync `TestProjects/`/`Package.swift`, rebuild, reinstall the VS Code extension, and reload |
| `ftester-profiles` | `/ftester:ftester-profiles` | Create machine, app and run profiles together in one pass (asks for iOS/Android and the app's display name/ID, then picks or creates a device) |
| `ftester-scenario` | `/ftester:ftester-scenario` | Author one Swift DSL scenario (`.swift`) in an already set-up project, from live exploration through compile verification |
| `ftester-mcp` | `/ftester:ftester-mcp` | Register just the MCP server (`ftester-mcp`) with Claude Code — no VS Code extension, project creation, or profiles |
| `ftester-remote-setup` | `/ftester:ftester-remote-setup` | Provision another Mac as a runner machine so scenarios can be dispatched to it over SSH |

`ftester-setup` is the entry point for a first-time install; the others assume it (or an
equivalent manual setup) has already run.

## The `ftester-scenario` flow

`/ftester:ftester-scenario` walks through:

1. **Confirm the target app** (its app profile) — a human checkpoint.
2. **Provision a device and live-explore it** to collect real selectors from the running app.
3. **Write the scenario** (`.swift`).
4. **Compile-verification gate.**
5. **dry-run gate** — device-free, a few seconds.
6. **Run on a device and confirm it behaves as intended** — a human checkpoint.

Skipping straight from writing to a device run means any error surfaces only after a device-run's
worth of waiting; the compile and dry-run gates catch most mistakes in seconds instead.

## Updating

```bash
claude plugin marketplace update foundation-tester
claude plugin update ftester@foundation-tester
```

Both commands are required — updating only the marketplace listing does not update the installed
plugin. Restart Claude Code afterward for the change to take effect.

### Link
- [index](../index.md)
