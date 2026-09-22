# VS Code Extension

The `vscode-fleetest` extension surfaces scenarios in VS Code's Test Explorer, and adds device
control, live inspection and result review around them. It works by spawning the same `fleetest`
CLI used from the terminal, so behavior matches the CLI and MCP entry points.

## Test Explorer

Scenarios appear in the Testing view as a folder → class → `@Test` method tree, built from
`TestProjects/<project>/scenarios/**/*.swift`. The target `<project>` comes from the
`fleetest.project` setting; when it is empty the extension auto-resolves it, creating
`TestProjects/default/` on startup with `fleetest project create default` if it is missing and selecting
that `default` project initially (see [Creating a project](../project/creating_project.md)). Each test
item offers three run profiles:

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

Command **"fleetest: Show Device Monitor"** (or **fleetest mobile** in the status bar at the
lower-left corner of VSCode) opens a webview panel of device tiles (one panel per
workspace). Each tile shows the device name, a platform badge (iOS/Android), a status badge, and
the current screen — streamed live by default via a headless helper
(`fleetest-simstream`/`fleetest-androidstream`), falling back to periodic screenshots if streaming
is unavailable.

- Status badges: **Connected** (green) — bridge attached, ready to drive; **Starting**
  (yellow) — device is up but the bridge hasn't attached yet; **Not started**
  (gray) — device is down.
- Right-click a tile to start or stop that one device (`fleetest api start-device`/`stop-device`).
  Device operations run one at a time through a shared queue, so queued tiles show a
  "Waiting..." badge.
- Toolbar buttons start/stop every device in view and restart the monitor process.
- The **run board** under the toolbar lists the runs going on right now, on this Mac and on every
  registered runner machine, with "N of M done" and an estimated time left — not just runs you
  started, but CLI runs and other people's runs too. Clicking a row selects that run's devices in
  the Line View.
- The Device Monitor tab is split into three views, top to bottom: the **Line View** (the row of
  device tiles), the **Grid View** (enlarged screens of the selected devices), and the **Run Log View**
  (the run log of the selected devices). Drag a divider to resize, click a view's header to collapse or
  expand it (the header row always stays visible, wherever you drag).
- The Grid View and the Run Log View show **only the devices selected in the Line View**. Clicking
  anywhere on a tile toggles its selection; clicking outside the tiles clears the selection. With
  nothing selected both views say "Select a device" (provisioning progress during a run still appears
  in the Run Log View). With exactly one device selected, the Grid View shows the enlarged screen and
  that device's run log side by side, and the Run Log View below folds itself so the same log is not
  shown twice.
- Clearing the **iOS** / **Android** checkboxes in the run board header hides that platform's
  devices from all four sections (Running, Device list, Selected devices and Run log). The
  devices themselves keep running; only the display changes.
- Turning **Live Updates** (in the Line View header) off stops streaming and capturing every
  device's screen to reduce the Mac's load. Tiles keep their last frame, dimmed (status keeps updating).
- The **Test Sessions** tab opens runs that were recorded (run profile `record: true`) and shows each
  scenario's video, a step tree, and the error list. **If the Device Monitor tab is showing when a run
  finishes**, the monitor switches to the Test Sessions tab and opens that run's recording as soon as
  it is ready (it does not switch while another tab is showing, nor for runs without recordings or
  cancelled runs).
  Between the last scenario finishing and the switch, "Editing recordings..." is shown to the right
  of the Run Tests button.
  The **Export Test Results** button in the player view's header writes the open session's results
  to an Excel (.xlsx) file; a dialog lets you choose where to save it.
- The **Profiles** tab lists, creates, copies, renames and deletes test projects themselves,
  and lists, creates, copies, renames, deletes and edits run/app profiles. A run profile's
  section shows the union of every run profile's devices with checkboxes (checked = this
  profile runs it), and its own "Add device" button.
- The **Settings** tab holds display, update, log-and-recording cleanup, and remote machine
  settings, including the update-check and update actions described below. The **Tools** section
  at its top has a "Processes" button that brings up that tab.
- The **Live Control** tab (below) and the **Processes** tab (list and stop fleetest's resident
  processes) are hidden at startup. Opening one brings its tab up; close it with the tab's ×.
- Right-clicking anywhere does not show the default Cut/Copy/Paste menu (except in text input fields).

## Live Control

A tab for touching a device directly from its screenshot, shown to the right of the device monitor's
**Device Monitor** tab. Open it with the command **"fleetest: Show Live Control"** or **Live Control**
in a tile's right-click menu (opens with that device selected). It also opens automatically when a test run starts (setting `fleetest.liveControlOnRun`):

| Gesture | Action |
|---|---|
| Click | Tap |
| Hold ~500ms without moving | Long press |
| Drag | Swipe (direction inferred from the drag vector) |
| Alt/Option + click | Double tap |
| Toolbar zoom in/out | Pinch (whole screen) |

An element list next to the screenshot lets you tap by row instead of by coordinate, and a text
field sends input to whatever the device has focused (tap the field first, then type).

You can keep driving the device after the app under test leaves the foreground (iOS). When the home
screen, the app switcher, another app or a system dialog comes to the front, live control follows
whatever is on screen — gestures land on it and the element list shows it. It switches back on its
own once the app returns to the front (if it does not, launch the app from the toolbar).

**Recording**: start recording, perform the flow, then stop — the extension turns the recorded
steps into a Swift scenario under `TestProjects/<project>/scenarios/Generated/` via
`fleetest api gen-scenario`. The generated file is build-verified immediately; if it fails to
compile it is parked under `scenarios/_disabled/` instead of being added to the tree.

## Results Dashboard

Command **"fleetest: Open Results Dashboard"** shows, in the device monitor's **Dashboard** tab, a summary of
`fleetest api results` for the project: recent runs, per-scenario success rate and duration,
flaky scenarios, device/worker breakdowns, a daily trend, slow scenarios, and other insights.

## Rerunning Failures and Reports

- **"Rerun Failed Tests"** re-runs only the scenarios that failed last time.
- **"Open Report"** opens the Markdown report for a scenario's last run (element list,
  screenshot, and — when available — self-healing suggestions).
- The Test Explorer toolbar's **"Show Failed Tests Only"** filter narrows the tree to failed tests.

## Self-Healing Review

Setting `fleetest.heal` to `true` adds `--set heal=true` to Run (not Run (dry-run)) and Debug, enabling
selector self-healing (fingerprint matching). If the run reports fix suggestions, a confirmation panel opens
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
Code's display language. You can also switch it from **"Display Language"** in the Settings tab.

## Cleaning Up Logs and Recordings

Recordings, reports, and logs pile up with every run, so each category has a size limit and the
oldest files are deleted first. The controls are in the Settings tab's **"Logs & recordings"**
section. They are stored as **this Mac's settings** (`fleetest api retention`), not VS Code
settings, so they also apply to tests you run directly from a terminal.

- **"Clean up in the background after a test run"** (on by default): cleanup runs in the
  background after each test run. It does not count toward the test run time.
- **Limits**: only a category whose usage reaches 90% of its limit is trimmed, oldest first, back
  down to 90%. `0` means keep nothing; clearing a field resets just that item to its default.

  | Item | Default limit |
  |---|---|
  | Device recordings and screenshots | 20 GB |
  | Recordings | 100 GB |
  | Reports | 1000 MB |
  | Logs | 500 MB |

- Each row shows the **current usage** on its right. Measuring takes about 20 seconds; until then
  it reads "Now - GB".
- **"Clean up now"**: deletes right away using the same rule. Before deleting, a confirmation
  dialog shows the total that will be removed.
- Result records (the pass/fail and timing JSON) are never deleted.

## Key Settings

| Setting | Default | Description |
|---|---|---|
| `fleetest.binaryPath` | `.build/debug/fleetest` | Path to the `fleetest` binary; falls back to `PATH` if not found |
| `fleetest.project` | `""` | Test project name; auto-resolved when empty (the only project, or `default` when there are several) |
| `fleetest.profile` | `""` | Run profile name; when set, it decides devices/app instead of `fleetest.platform`/`port`/`serial` |
| `fleetest.heal` | `false` | Enable `--set heal=true` on Run/Debug and open the self-healing review panel |
| `fleetest.buildBeforeRun` | `true` | Build the Swift project before each run |
| `fleetest.lptScheduling` | `true` | Schedule longer-running scenarios first (LPT), using recent run history |
| `fleetest.monitorInterval` | `2` | Device Monitor polling interval, in seconds |
| `fleetest.liveControlOnRun` | `true` | Auto-open Live Control when a (non-dry-run) test starts |
| `fleetest.language` | `"auto"` | Extension UI display language |
| `fleetest.updateCheck` | `"auto"` | Automatic once-a-day update check on startup |

### Link
- [index](../index.md)
