# Getting Started (Installation)

How to install, update, and uninstall Fleetest.

## 1. Environment

For the supported macOS, Xcode, Android SDK and other requirements, see [Environment](overview/environments.md).

## 2. Before you start

- **If you test iOS**
  - Install Xcode and the iOS Simulator runtime
- **If you test Android**
  - Install Android Studio (Android SDK)
- **AI assistant**
  - Install an AI assistant that supports MCP (Claude Code, Codex, Cline, Cursor, Copilot, and so on).
    With any of them, you have the assistant carry out the installation. For Claude Code:

```bash
brew install claude-code
```

## 3. Installing Fleetest

1. Open a **new, test-only folder** in VSCode, start your AI assistant, and ask it:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

   It clones, builds, and creates the project (you create the profiles in the [Quick Start](quick-start.md))

2. Run `Developer: Reload Window` in VSCode

3. Click **fleetest mobile** in the status bar at the lower-left corner of VSCode (it opens the device monitor)

> **Other than Claude Code**: with Claude Code, the setup also writes the MCP registration
> (`.mcp.json`). With any other AI assistant, you register the MCP server in the assistant's own
> settings (fleetest never writes to your assistant's global settings). See
> [Other agents](reference/tools/other_agents.md#2-register-the-mcp-server) for how.
>
> **Using Codex**: do step 1 in a session started with `codex --sandbox danger-full-access`. The
> default sandbox blocks `swift build` and driving the Simulator. After setup, the `ft_*` work runs
> with the default settings (details in
> [Other agents](reference/tools/other_agents.md#using-codex-the-sandbox)).

## 4. Updating Fleetest

When an update is available, the VSCode extension notifies you on startup (at most once a day).
It only checks — it never pulls the update in by itself. If you don't want the notification, set
`fleetest.updateCheck` to `off`.

### From VSCode

The device monitor's "Settings" tab is where you check and apply updates. When an update is
available, an "Update now" button appears next to the tab; clicking it starts the update. When
it finishes, click **Reload window** (otherwise the pre-update extension keeps running). Details
in [VSCode extension](reference/tools/vscode_extension.md).

### From a terminal

Ask your AI assistant to update fleetest (in Claude Code, `/fleetest-update`), or run the single
command `bash <TOOL_ROOT>/Scripts/update.sh`: pull, build, the extension, and the skills. If there
is nothing to update it does nothing. Pass `--force` to redo everything. If the skills were
refreshed, restart your AI assistant.

> **If you have modified the clone (`foundation-tester`) yourself**: during an update, local
> changes in the clone are discarded without confirmation. Test assets live in the work folder,
> and the clone is treated as distributed material. Commit anything you want to keep first, or
> pass `--keep-local`.
>
> The full log is kept in `<work folder>/.fleetest/install-*.log`. The clone and the first build
> take a few minutes, but a line is printed as each step finishes, so it's fine to keep waiting.

## 5. Uninstalling Fleetest

### VSCode extension

Uninstall it from VSCode's Extensions view.

### Work folder

Quit VSCode, then delete it via Finder or `rm`.

If you want to keep the work folder, remove the range between `<!-- fleetest:begin -->` and
`<!-- fleetest:end -->` in both `AGENTS.md` and `CLAUDE.md` (the body is in `AGENTS.md`; `CLAUDE.md` only imports it). That is the agent guidance the installer placed there;
nothing outside the range was touched. If you registered the MCP server with another agent
yourself, remove that configuration too. Also delete the skills the installer copied
(`.claude/skills/fleetest-*` and `.claude/skills/.fleetest-copied`).

### Leftover files and processes

After stopping the fleetest processes (commands below), also delete the following.

- The fleetest clone (by default `foundation-tester` next to your work folder; with its build folder it takes a few GB)
- `~/.fleetest` (records of runs on this Mac and the like) and `~/Library/Logs/fleetest` (logs)
- Optionally `~/.config/fleetest/config.json`
- Virtual devices you created for fleetest, if you no longer need them — delete them from Xcode's
  "Devices and Simulators" or Android Studio's Device Manager

If `.build` reappears after you delete the work folder, fleetest processes are still running.

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 6. Troubleshooting

If you run into a problem, ask your AI assistant. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

### Link
- [index](index.md)
