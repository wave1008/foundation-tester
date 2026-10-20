# dry-run (No-Load-Run)

[in Japanese(日本語)](dry_run_ja.md)

`fleetest run --dry-run` (Shirates' No-Load-Run equivalent) enumerates and validates a scenario's
steps **without touching a device or calling FM**. It catches mistakes that would otherwise only
surface during, or after, a slow device run — in seconds.

```bash
fleetest run --dry-run --scenario LoginTest
```

MCP exposes the same check as `ft_dry_run`; the VS Code extension runs it via
`fleetest api run --dry-run` (the Test Explorer's "Run (dry-run)" action).

## What it catches

| Problem | How it's caught |
|---|---|
| Selector syntax errors | The selector expression parser runs before any device call |
| Mistakes inside `ifCanSelect { }` / `.ifElse { }` | In a dry-run **both blocks are executed** regardless of the condition, so selector syntax errors and unknown `#id`s inside either one are reported |
| An `expectation { }` block with zero assertions | Counted the same way `verify` counts assertions (`exist`/`notExist`/`textIs` and friends, `thisIs` variants, `appIs`; `select` does not count). A scenario with **zero** assertions overall gets a stronger warning |
| `#id`s that don't exist in any screen you've captured | Checked against the project's selector inventory (`<project>/.fleetest/selector-inventory.json`), built by `ft_snapshot` calls made while writing the scenario |
| Commands the profile's devices cannot run (only with `--profile`) | The commands of the steps that ran are checked against the engine and kind of every device that could take the scenario (all devices of that OS). See the table below |

Notes on the last check: it only warns about screens you have actually captured — if the
inventory has no record for a given screen (or platform), dry-run stays silent rather than
guessing. It also stays silent while the inventory is thin: the warning only fires when at least
two thirds of a scenario's `#id`s are already in the inventory (a single captured screen would
otherwise flag most existing scenarios as wrong). Only exact-match `#id`s are checked — wildcard
forms (`#row_*`) and labels are excluded, since labels normally change with copy edits.

A dry-run is not static analysis: it actually executes the scenario and only skips the device
calls. So nothing is caught for content inside `ios { }` / `android { }` blocks that did not
execute for the platform being checked (to cover both OSes, dry-run once per platform).

## Commands the profile's devices cannot run

With `--profile`, a dry-run warns when one of the following commands cannot run on a device of that profile
(a ⚠️ line; the dry-run still passes or fails as before). On a device run these fail only when that step is reached
(`fold` / `unfold` / `hinge` on a device that cannot fold are still skipped as not applicable without being sent).
In the VS Code extension's dry-run the warnings appear in the Output panel, not in each test's result in the Test Explorer.

| Device | Commands warned about |
|---|---|
| iOS device with `engine: inapp` | `home` / `back` / `appSwitcher` / `tapAppIcon` / `fold` / `unfold` / `hinge` / `swipePointToPoint` / `swipeBy` / `swipeElementToElement` / `hold` / `gesture` / `waitForSettle` |
| Physical iPhone | `fold` / `unfold` / `hinge` / `addMedia` |

```
⚠️ Login.S0010: home at 01_login.swift:30 cannot run on device "iPhone 17 Pro-01" — its engine is inapp, which cannot hand this command to XCUITest (use hybrid or xcuitest for that device)
```

Only cases decided by **the command name alone** are warned about. These cannot be seen from a dry-run and are not checked:

- Decided by an argument: `tap(holdSeconds:)` (a long press, above 0), and `appIs` / `launchApp` / `restartApp` given another app
- Decided by the app's UI framework: `doubleTap` / `pinchOut` / `pinchIn` (UIKit / SwiftUI / RN), `swipe` / `flick*` / `scroll*`,
  and `clearInput` / `pressEnter` on Flutter
- `iosAlertHandler` and selectors pointing at SpringBoard dialogs (out of reach with `engine: inapp`)

The default engine (hybrid) hands what the in-app engine cannot do to XCUITest, so the iOS in-app row never fires for it.

## What it does not do

- It never contacts a device or an Emulator/Simulator, and never calls FM.
- `--profile` is not used to prepare any device. It decides, from the profile's devices, which of `ios { }` /
  `android { }` is checked for scenarios that declare no platform (`ios` if the profile has an iOS device, otherwise
  `android`; the same rule as the VSCode extension's dry-run). Without a profile, `--platform` decides and the command
  check above does not run. MCP's `ft_dry_run` takes no profile, so it does not run this check.
- It does not write a report, and its result is not recorded for `--failed` to pick up later.

`--scenario` / `--folder` / `--project` / `--quiet` all work the same as a normal run, and a
failed check sets exit code `1` — so `fleetest run --dry-run` (with no `--scenario`) is a cheap
gate to run before every device run across a whole project.

### Link
- [index](../../index.md)
