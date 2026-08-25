# VS Code Extension

The `vscode-fleetest` extension surfaces scenarios in VS Code's Test Explorer, and adds device
control, live inspection and result review around them. It works by spawning the same `fleetest`
CLI used from the terminal, so behavior matches the CLI and MCP entry points.

## Test Explorer

Scenarios appear in the Testing view as a folder → class → `@Test` method tree, built from
`TestProjects/<project>/scenarios/**/*.swift`. Each test item offers three run profiles:

- **Run** — executes the scenario on a device.
- **Run (dry-run)** — validates the scenario without a device (selector syntax, unreachable
  scenes, assertion-less expectations, unknown `#id`s from a saved snapshot).
- **Debug** — runs under a Debug Adapter Protocol adapter: set a breakpoint on a command line
  inside an `action { }` block, then step over, continue, or stop from the debug toolbar.

Setting `fleetest.profile` routes Run/Run (dry-run)/Debug through `fleetest api run --profile
<name>` instead of the raw `fleetest.platform`/`fleetest.port`/`fleetest.serial` settings — devices
are provisioned and the app is auto-installed by the run profile. A physical device or simulator
must already be booted for a real run; Run (dry-run) needs no device at all.

## Steps View

A read-only **fleetest Steps** tree view (in the Testing view container) follows the cursor: put
the cursor inside a `@Test` method and it lists that scenario's `scene` groups and steps.
Clicking a step jumps to the matching source line. It also opens from a scenario's right-click
menu ("fleetest: Show Step List").

## Device Monitor

Command **"fleetest: Show Device Monitor"** opens a webview panel of device tiles (one panel per
workspace). Each tile shows the device name, a platform badge (iOS/Android), a status badge, and
the current screen — streamed live by default via a headless helper
(`fleetest-simstream`/`fleetest-androidstream`), falling back to periodic screenshots if streaming
is unavailable.

- Status badges: **Connected** (green) — bridge attached, ready to drive; **Starting**
  (yellow) — device is up but the bridge hasn't attached yet; **Not started**
  (gray) — device is down.
- Right-click a tile to start or stop that one device (`fleetest api device-up`/`device-down`).
  Device operations run one at a time through a shared queue, so queued tiles show a
  "Waiting..." badge.
- Toolbar buttons start/stop every device on the machine profile and restart the monitor process.
- The **Profiles** tab lists, creates, copies, renames, deletes and edits run/app/
  machine profiles.
- The **Settings** tab holds display and update options, including the update-check and
  update actions described below.

## Live Control

Command **"fleetest: Show Live Control"** opens an independent panel for touching a device directly
from its screenshot:

| Gesture | Action |
|---|---|
| Click | Tap |
| Hold ~500ms without moving | Long press |
| Drag | Swipe (direction inferred from the drag vector) |
| Alt/Option + click | Double tap |
| Toolbar zoom in/out | Pinch (whole screen) |

An element list next to the screenshot lets you tap by row instead of by coordinate, and a text
field sends input to the last-tapped element (or the focused element if none was tapped).

**Recording**: start recording, perform the flow, then stop — the extension turns the recorded
steps into a Swift scenario under `TestProjects/<project>/scenarios/Generated/` via
`fleetest api gen-scenario`. The generated file is build-verified immediately; if it fails to
compile it is parked under `scenarios/_disabled/` instead of being added to the tree.

## Results Dashboard

Command **"fleetest: Open Results Dashboard"** opens a panel summarizing
`fleetest api results` for the project: recent runs, per-scenario success rate and duration,
flaky scenarios, device/worker breakdowns, a daily trend, slow scenarios, and other insights.

## Rerunning Failures and Reports

- **"Rerun Failed Tests"** re-runs only the scenarios that failed last time.
- **"Open Report"** opens the Markdown report for a scenario's last run (element list,
  screenshot, and — when available — FM triage).
- The Test Explorer toolbar's **"Show Failed Tests Only"** filter narrows the tree to failed tests.

## Self-Healing Review

Setting `fleetest.heal` to `true` adds `--heal` to Run (not Run (dry-run)) and Debug, enabling
locator self-healing. If the run reports fix suggestions, a confirmation panel opens
automatically afterward: each candidate shows the file/line, the old and new selector (the new
one is editable), an optional description, and a live diff preview. Approving applies the change
directly to the scenario source; a candidate whose target line no longer matches the recorded old
selector is shown as not applicable.

## Update Check

The Settings tab's **"Updates"** section is the one place updates are checked and applied:

- **"Check for updates"** reports whether the tool is up to date, an update is available, the repo is
  version-pinned, or the check failed — read-only, no repository changes.
- **"Update now"** appears next to the tab only when an update is available; it pulls, rebuilds, and
  reinstalls the extension, then prompts to reload the window.
- Command **"fleetest: Check for Updates"** (`fleetest.checkForUpdate`) always returns a result even when the
  once-a-day interval, a dismissed version, or `fleetest.updateCheck: off` would otherwise silence
  the automatic check.

`fleetest.updateCheck` (`auto`/`off`) controls the automatic once-a-day startup check, which only
reads `git ls-remote` and never modifies the repository.

## Display Language

`fleetest.language` (`auto`/`ja`/`en`) controls the extension's own UI text. `auto` follows VS
Code's display language.

## Key Settings

| Setting | Default | Description |
|---|---|---|
| `fleetest.binaryPath` | `.build/debug/fleetest` | Path to the `fleetest` binary; falls back to `PATH` if not found |
| `fleetest.project` | `""` | Test project name; auto-resolved when empty and only one project exists |
| `fleetest.profile` | `""` | Run profile name; when set, it decides devices/app instead of `fleetest.platform`/`port`/`serial` |
| `fleetest.heal` | `false` | Enable `--heal` on Run/Debug and open the self-healing review panel |
| `fleetest.buildBeforeRun` | `true` | Build the Swift project before each run |
| `fleetest.lptScheduling` | `true` | Schedule longer-running scenarios first (LPT), using recent run history |
| `fleetest.monitorInterval` | `2` | Device Monitor polling interval, in seconds |
| `fleetest.liveControlOnRun` | `true` | Auto-open Live Control when a (non-dry-run) test starts |
| `fleetest.language` | `"auto"` | Extension UI display language |
| `fleetest.updateCheck` | `"auto"` | Automatic once-a-day update check on startup |

### Link
- [index](../index.md)
