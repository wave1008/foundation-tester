# Getting Started (Installation)

Ftester is a testing tool for iOS / Android apps.

## Distribution policy

Because it targets macOS and Xcode beta releases, there is no binary distribution at this time.
You install it through the Claude Code plugin, which clones the repository and builds it.

## 1. Requirements

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| iOS | Xcode 26+, iOS simulator runtime, xcodegen |
| Android (optional) | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer (verified on v24 and v26) |

Some features (visual verification) require macOS 27+.

## 2. Before you start

To make the Ftester installation go smoothly, do the following beforehand.

- Xcode
  - Install Xcode itself
  - Create and boot the Simulator you want to use for testing
- Android Studio
  - Install Android Studio itself
  - Create and boot the AVD you want to use for testing
  - Creating an AVD from within ftester (the monitor's "Add Device") requires the Android SDK
    Command-line Tools. If they are not installed, you can install them from the same dialog's
    "Install Command-line Tools" button (or `ftester api install-cmdline-tools`), so no
    preparation is needed for this beforehand.

## 3. Installing Ftester

1. Install the `claude` CLI if you don't have it already

```bash
brew install claude-code
```

2. Add the ftester plugin

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin install ftester@foundation-tester --scope user
```

3. Open a **new, test-only folder** in VSCode

4. Run `/ftester:ftester-setup` in the Claude Code panel.
This performs the clone, build, project creation, and profile setup.

5. Run `Developer: Reload Window` in VSCode

6. Click the **device monitor** shown in the lower-left corner of VSCode


If you want to go through the steps manually one at a time, see `.claude/skills/ftester-setup/SKILL.md`.


## 4. Updating Ftester

The VSCode extension automatically checks for updates on startup (at most once a day) and
notifies you. It only checks — it does not pull in the update. If you don't want the
notification, set `ftester.updateCheck` to `off`.

**Update status can be checked from the device monitor's "Settings" tab** (the "Check for
updates" button). When an update is found, a dialog asks whether to update now.
When an update is available, **an "Update now" button appears next to the tab** (shown regardless
of which tab you're viewing). Clicking it starts pulling in the update immediately. Progress is
shown via a spinner and a notification in the lower-right of the screen, and the detailed log
streams to VSCode's **OUTPUT (ftester)**. You can also jump there from the notification's "Open
Settings tab" link. When it finishes, a dialog prompts you to reload — click **Reload window** (if you
don't, the pre-update extension keeps running).

You can also check from the Command Palette's **`ftester: Check for Updates`** (this always
checks, regardless of the interval or "don't notify for this version" setting). From a terminal,
run `bash <TOOL_ROOT>/Scripts/update-check.sh` (neither of these changes anything).

To pull in the update:

1. Run the following in a terminal

```bash
claude plugin marketplace update foundation-tester
claude plugin update ftester@foundation-tester
```

2. Start a new Claude Code session and run `/ftester:ftester-update`

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
> `<work folder>/.ftester/install-*.log` (the location is shown at the start and at the end; pass
> `--verbose` to also print it to the screen).
> Progress is shown one line at a time as each step finishes, so it's fine to keep waiting even
> if it looks unresponsive (the clone and initial build can take a few minutes).


## 5. Uninstalling Ftester

### Uninstall the plugin

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall ftester@foundation-tester
```

### Uninstall the VSCode extension

- Uninstall it from VSCode's Extensions view

### Delete the work folder

- Quit VSCode, then delete it via Finder or `rm`
- **If you want to keep the work folder**, also remove the range between
  `<!-- ftester:begin -->` and `<!-- ftester:end -->` in `CLAUDE.md` (this is the Claude
  Code guidance the installer placed there; nothing outside that range was touched)

### Delete files

- Optionally also delete `~/.config/ftester/config.json`

### Clean up processes
- If `.build` reappears even after deleting the work folder, run the following

```bash
pgrep -fl 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
pkill  -f 'ftester-mcp|/ftester (api|run|bridge|devices)|ftester-(simstream|androidstream|devicepoll)|xcodebuild.*FTesterRunner'
```

## 6. Troubleshooting

- If you run into a problem, ask Claude Code for help.

### Link
- [index](index.md)
