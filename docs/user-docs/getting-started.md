# Getting Started (Installation)

How to install, update, and uninstall Fleetest.

There is no binary distribution at this time. Fleetest targets beta releases of macOS / Xcode,
so it is installed through the Claude Code plugin, which clones the repository and builds it.
The agent drives the clone and the build, so there is little to do by hand.

## 1. Requirements

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| If you test iOS | Xcode 26+, iOS simulator, xcodegen |
| If you test Android | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer |

To use the Foundation Models features such as self-healing and visual verification, **the Mac's
system language must be English** (the model is English-only for now). Visual verification also
requires macOS 27+. Details in [Requirements](overview/environments.md).

## 2. Before you start

To keep the installation smooth, have the devices you will test on ready beforehand.

- **If you test iOS**: install Xcode, then create and boot the simulator you want to use
- **If you test Android**: install Android Studio, then create and boot the AVD you want to use.
  Prefer a **Google APIs** system image over a Play Store one — Play Store images are `user`
  builds, and a release build of your app cannot expose its WebView content on them (see
  [selector/webview.md](selector/webview.md))

## 3. Installing Fleetest

1. Install the `claude` CLI if you don't have it

```bash
brew install claude-code
```

2. Add the fleetest plugin

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin marketplace update foundation-tester
claude plugin install fleetest@foundation-tester --scope user
```

> The second line, `marketplace update`, refreshes the cache on a machine that already has the
> marketplace added. With a stale cache the install fails with
> `Plugin "fleetest" not found in marketplace`. On a fresh machine it does nothing.

> **If the pre-rename `ftester@foundation-tester` is installed, remove it first.** The old
> `/ftester:*` skills would stay behind, pointing at a command that no longer exists. The
> marketplace name did not change, so there is nothing to re-add.
>
> ```bash
> claude plugin uninstall ftester@foundation-tester
> ```

3. Open a **new, test-only folder** in VSCode

4. Run `/fleetest:fleetest-setup` in your agent's panel. It clones, builds, creates the project,
   and sets up the profiles

5. Run `Developer: Reload Window` in VSCode

6. Click the **device monitor** shown in the lower-left corner of VSCode

If you want to go through the steps manually one at a time, see
`.claude/skills/fleetest-setup/SKILL.md`.

Using another agent (Codex, Cline, …)? See [Other agents](tools/other_agents.md). The runbooks
are tool-neutral and apply unchanged, but you run the installer and register the MCP server
yourself.

## 4. Updating Fleetest

When an update is available, the VSCode extension notifies you on startup (at most once a day).
It only checks — it never pulls the update in by itself. If you don't want the notification, set
`fleetest.updateCheck` to `off`.

### From VSCode

The device monitor's "Settings" tab is where you check and apply updates. When an update is
available, an "Update now" button appears next to the tab; clicking it starts the update. When
it finishes, click **Reload window** (otherwise the pre-update extension keeps running). Details
in [VSCode extension](tools/vscode_extension.md).

### From a terminal

```bash
claude plugin marketplace update foundation-tester
claude plugin update fleetest@foundation-tester
```

Then start a new agent session and run `/fleetest:fleetest-update`.

A single command, `bash <TOOL_ROOT>/Scripts/update.sh`, does the same thing: pull, build, the
extension, and the plugin update. If there is nothing to update it does nothing. Pass `--force`
to redo everything.

> **If you have modified the clone (`foundation-tester`) yourself**: during an update, local
> changes in the clone are discarded without confirmation. Test assets live in the work folder,
> and the clone is treated as distributed material. Commit anything you want to keep first, or
> pass `--keep-local`.
>
> The full log is kept in `<work folder>/.fleetest/install-*.log`. The clone and the first build
> take a few minutes, but a line is printed as each step finishes, so it's fine to keep waiting.

## 5. Uninstalling Fleetest

### Plugin

```bash
claude plugin marketplace remove foundation-tester
claude plugin uninstall fleetest@foundation-tester
```

If the pre-rename `ftester@foundation-tester` is still there, uninstall it the same way.

### VSCode extension

Uninstall it from VSCode's Extensions view.

### Work folder

Quit VSCode, then delete it via Finder or `rm`.

If you want to keep the work folder, remove the range between `<!-- fleetest:begin -->` and
`<!-- fleetest:end -->` in `CLAUDE.md`. That is the agent guidance the installer placed there;
nothing outside the range was touched. If you registered the MCP server with another agent
yourself, remove that configuration too.

### Leftover files and processes

Optionally delete `~/.config/fleetest/config.json` as well.

If `.build` reappears after you delete the work folder, fleetest processes are still running.

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 6. Troubleshooting

If you run into a problem, ask Claude Code. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

### Link
- [index](index.md)
