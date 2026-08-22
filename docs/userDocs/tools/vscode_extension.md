# VS Code Extension

The `vscode-ftester` extension surfaces scenarios in VS Code's Test Explorer, and adds device
control, live inspection and result review around them. It works by spawning the same `ftester`
CLI used from the terminal, so behavior matches the CLI and MCP entry points.

## Test Explorer

Scenarios appear in the Testing view as a folder → class → `@Test` method tree, built from
`TestProjects/<project>/scenarios/**/*.swift`. Each test item offers three run profiles:

- **Run** — executes the scenario on a device.
- **Run (dry-run)** — validates the scenario without a device (selector syntax, unreachable
  scenes, assertion-less expectations, unknown `#id`s from a saved snapshot).
- **Debug** — runs under a Debug Adapter Protocol adapter: set a breakpoint on a command line
  inside an `action { }` block, then step over, continue, or stop from the debug toolbar.

Setting `ftester.profile` routes Run/Run (dry-run)/Debug through `ftester api run --profile
<name>` instead of the raw `ftester.platform`/`ftester.port`/`ftester.serial` settings — devices
are provisioned and the app is auto-installed by the run profile. A physical device or simulator
must already be booted for a real run; Run (dry-run) needs no device at all.

## Steps View

A read-only **ftester ステップ** tree view (in the Testing view container) follows the cursor: put
the cursor inside a `@Test` method and it lists that scenario's `scene` groups and steps.
Clicking a step jumps to the matching source line. It also opens from a scenario's right-click
menu ("ftester: ステップ一覧を表示").

## Device Monitor

Command **"ftester: デバイスモニターを表示"** opens a webview panel of device tiles (one panel per
workspace). Each tile shows the device name, a platform badge (iOS/Android), a status badge, and
the current screen — streamed live by default via a headless helper
(`ftester-simstream`/`ftester-androidstream`), falling back to periodic screenshots if streaming
is unavailable.

- Status badges: **接続済み** (connected, green) — bridge attached, ready to drive; **起動中**
  (booting, yellow) — device is up but the bridge hasn't attached yet; **未起動** (not running,
  gray) — device is down.
- Right-click a tile to start or stop that one device (`ftester api device-up`/`device-down`).
  Device operations run one at a time through a shared queue, so queued tiles show a
  "待機中..." (waiting) badge.
- Toolbar buttons start/stop every device on the machine profile and restart the monitor process.
- The **プロファイル** (Profiles) tab lists, creates, copies, renames, deletes and edits run/app/
  machine profiles.
- The **設定** (Settings) tab holds display and update options, including the update-check and
  update actions described below.

## Live Control

Command **"ftester: ライブ操作を表示"** opens an independent panel for touching a device directly
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
`ftester api gen-scenario`. The generated file is build-verified immediately; if it fails to
compile it is parked under `scenarios/_disabled/` instead of being added to the tree.

## Results Dashboard

Command **"ftester: 結果ダッシュボードを開く"** opens a panel summarizing
`ftester api results` for the project: recent runs, per-scenario success rate and duration,
flaky scenarios, device/worker breakdowns, a daily trend, slow scenarios, and other insights.

## Rerunning Failures and Reports

- **"失敗したテストを再実行"** re-runs only the scenarios that failed last time.
- **"レポートを開く"** opens the Markdown report for a scenario's last run (element list,
  screenshot, and — when available — FM triage).
- The Test Explorer toolbar's **"失敗したテストのみ表示"** filter narrows the tree to failed tests.

## Self-Healing Review

Setting `ftester.heal` to `true` adds `--heal` to Run (not Run (dry-run)) and Debug, enabling
locator self-healing. If the run reports fix suggestions, a confirmation panel opens
automatically afterward: each candidate shows the file/line, the old and new selector (the new
one is editable), an optional description, and a live diff preview. Approving applies the change
directly to the scenario source; a candidate whose target line no longer matches the recorded old
selector is shown as not applicable.

## Update Check

The Settings tab's **"更新"** section is the one place updates are checked and applied:

- **"更新を確認"** reports whether the tool is up to date, an update is available, the repo is
  version-pinned, or the check failed — read-only, no repository changes.
- **"更新する"** appears next to the tab only when an update is available; it pulls, rebuilds, and
  reinstalls the extension, then prompts to reload the window.
- Command **"ftester: 更新を確認"** (`ftester.checkForUpdate`) always returns a result even when the
  once-a-day interval, a dismissed version, or `ftester.updateCheck: off` would otherwise silence
  the automatic check.

`ftester.updateCheck` (`auto`/`off`) controls the automatic once-a-day startup check, which only
reads `git ls-remote` and never modifies the repository.

## Display Language

`ftester.language` (`auto`/`ja`/`en`) controls the extension's own UI text. `auto` follows VS
Code's display language.

## Key Settings

| Setting | Default | Description |
|---|---|---|
| `ftester.binaryPath` | `.build/debug/ftester` | Path to the `ftester` binary; falls back to `PATH` if not found |
| `ftester.project` | `""` | Test project name; auto-resolved when empty and only one project exists |
| `ftester.profile` | `""` | Run profile name; when set, it decides devices/app instead of `ftester.platform`/`port`/`serial` |
| `ftester.heal` | `false` | Enable `--heal` on Run/Debug and open the self-healing review panel |
| `ftester.buildBeforeRun` | `true` | Build the Swift project before each run |
| `ftester.lptScheduling` | `true` | Schedule longer-running scenarios first (LPT), using recent run history |
| `ftester.monitorInterval` | `2` | Device Monitor polling interval, in seconds |
| `ftester.liveControlOnRun` | `true` | Auto-open Live Control when a (non-dry-run) test starts |
| `ftester.language` | `"auto"` | Extension UI display language |
| `ftester.updateCheck` | `"auto"` | Automatic once-a-day update check on startup |

### Link
- [index](../index.md)
