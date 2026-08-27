# Getting Started (Installation)

Fleetest is a testing tool for iOS / Android apps.

## Distribution policy

Because it targets macOS and Xcode beta releases, there is no binary distribution at this time.
You install it through the Claude Code plugin, which clones the repository and builds it.

## 1. Requirements

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| iOS (if you test iOS) | Xcode 26+, iOS simulator runtime, xcodegen |
| Android (if you test Android) | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer (verified on v24 and v26) |

Some features (visual verification) require macOS 27+.

FM (Foundation Models) features are **experimental and English-only during 2026** (Japanese
support is expected in 2027). **The Mac's system language must be English** — see
[overview/environments.md](overview/environments.md).

## 2. Before you start

To make the Fleetest installation go smoothly, do the following beforehand.

- Xcode
  - Install Xcode itself
  - Create and boot the Simulator you want to use for testing
- Android Studio
  - Install Android Studio itself
  - Create and boot the AVD you want to use for testing
  - Creating an AVD from within fleetest (the monitor's "Add Device") requires the Android SDK
    Command-line Tools. If they are not installed, you can install them from the same dialog's
    "Install Command-line Tools" button (or `fleetest api install-cmdline-tools`), so no
    preparation is needed for this beforehand.

## 3. Installing Fleetest

1. Install the `claude` CLI if you don't have it already

```bash
brew install claude-code
```

2. Add the fleetest plugin

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin marketplace update foundation-tester
claude plugin install fleetest@foundation-tester --scope user
```

> The second line, `marketplace update`, is there for machines that **already have the
> marketplace added**. `add` sees it is already on disk and fetches nothing, so a stale cache
> fails with `Plugin "fleetest" not found in marketplace`. On a fresh machine it does nothing.

> **If you installed the pre-rename plugin (`ftester@foundation-tester`), remove it first.**
> The plugin was renamed, so the two sit side by side and the old `/ftester:*` skills keep
> pointing at a command (`ftester`) and a state directory (`.ftester/`) that no longer exist.
> The marketplace name (`foundation-tester`) did not change, so there is nothing to re-add.

```bash
claude plugin uninstall ftester@foundation-tester
```

3. Open a **new, test-only folder** in VSCode

4. Run `/fleetest:fleetest-setup` in your agent's panel (`$fleetest-setup` in Codex).
This performs the clone, build, project creation, and profile setup.

5. Run `Developer: Reload Window` in VSCode

6. Click the **device monitor** shown in the lower-left corner of VSCode


If you want to go through the steps manually one at a time, see `.claude/skills/fleetest-setup/SKILL.md`.

**Using Codex?** The same runbooks apply. Install the skills with
`curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh -s -- --agent codex`
and invoke them as `$fleetest-setup`. **The default sandbox cannot drive devices**, so read the
sandbox settings in [Codex](tools/codex_skills.md) first.


## 4. Updating Fleetest

The VSCode extension automatically checks for updates on startup (at most once a day) and
notifies you. It only checks — it does not pull in the update. If you don't want the
notification, set `fleetest.updateCheck` to `off`.

**Update status can be checked from the device monitor's "Settings" tab** (the "Check for
updates" button). When an update is found, a dialog asks whether to update now.
When an update is available, **an "Update now" button appears next to the tab** (shown regardless
of which tab you're viewing). Clicking it starts pulling in the update immediately. Progress is
shown via a spinner and a notification in the lower-right of the screen, and the detailed log
streams to VSCode's **OUTPUT (fleetest)**. You can also jump there from the notification's "Open
Settings tab" link. When it finishes, a dialog prompts you to reload — click **Reload window** (if you
don't, the pre-update extension keeps running).

You can also check from the Command Palette's **`fleetest: Check for Updates`** (this always
checks, regardless of the interval or "don't notify for this version" setting). From a terminal,
run `bash <TOOL_ROOT>/Scripts/update-check.sh` (neither of these changes anything).

To pull in the update:

1. Run the following in a terminal

```bash
claude plugin marketplace update foundation-tester
claude plugin update fleetest@foundation-tester
```

2. Start a new agent session and run `/fleetest:fleetest-update` (`$fleetest-update` in Codex)

If you're not using Claude Code, run `bash <TOOL_ROOT>/Scripts/update.sh` (this does the pull,
build, extension, and plugin update in a single command). If there's nothing to update, it does
nothing (use `--force` if you want to redo everything, for example after a previous run failed
partway through).

> **Note when you have modified the clone (`foundation-tester`) yourself**
> During an update, local changes in the clone are **discarded without confirmation** (test
> assets live in the work folder, and the clone is treated as distributed material). If you have
> changes you want to keep, pass `--keep-local`, or commit / `git stash` them first. Build
> artifacts such as `.build/` are not removed.
> The detailed `swift build` / npm logs are not shown on screen, but the full text is kept in
> `<work folder>/.fleetest/install-*.log` (the location is shown at the start and at the end; pass
> `--verbose` to also print it to the screen).
> Progress is shown one line at a time as each step finishes, so it's fine to keep waiting even
> if it looks unresponsive (the clone and initial build can take a few minutes).


## 5. Uninstalling Fleetest

### Uninstall the plugin

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall fleetest@foundation-tester
```

If the pre-rename `ftester@foundation-tester` is still there, `claude plugin uninstall` it the same way.

### Uninstall the VSCode extension

- Uninstall it from VSCode's Extensions view

### Delete the work folder

- Quit VSCode, then delete it via Finder or `rm`
- **If you want to keep the work folder**, also remove the range between
  `<!-- fleetest:begin -->` and `<!-- fleetest:end -->` in `CLAUDE.md` (`AGENTS.md` for Codex) —
  this is the agent guidance the installer placed there; nothing outside that range was touched
- If you registered the MCP server with Codex, also remove `[mcp_servers.fleetest]` and
  `[mcp_servers.fleetest.env]` from `~/.codex/config.toml`

### Delete files

- Optionally also delete `~/.config/fleetest/config.json`

### Clean up processes
- If `.build` reappears even after deleting the work folder, run the following

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 6. Troubleshooting

- If you run into a problem, ask Claude Code for help.

### Link
- [index](index.md)
