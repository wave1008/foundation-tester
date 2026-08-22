# Run Profile Keys

`profiles/runs/<name>.json` combines an app, a device list and run-time settings. This page
lists every recognized key. See [profiles.md](./profiles.md) for the app/machine profiles it
references, and [running_scenarios.md](../running/running_scenarios.md) for how `--profile`
selects one.

```json
{ "app": "sampleapp",
  "devices": [ { "name": "simulator1" }, { "name": "simulator2" }, { "name": "emulator1" } ],
  "fm": true, "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `app` | string | — | Name of the `apps/<name>.json` profile to use |
| `devices` | array | — | Device names to run on (from the resolved machine profile; iOS/Android can mix in the same list) |
| `fm` | bool | `true` | Master switch for all FM (Foundation Models) features. `false` disables self-healing, `falsePositiveCheck`, `screenLooksLike` and failure triage entirely, regardless of the individual toggles below |
| `heal` | bool | `true` | Allow FM-based locator self-healing (see [self_healing.md](../running/self_healing.md)) |
| `falsePositiveCheck` | bool | `false` | Occlusion-guard verification on `exist`/`textIs` etc. (opt-in: FM cost and a false-flip risk) |
| `screenLooksLike` | bool | `true` | Enable `screenLooksLike` (FM visual verification). When `false`, those steps are skipped rather than failing |
| `reportDir` | string | `"reports"` | Where to write Markdown reports (relative to the project root) |
| `defaultTimeout` | number (seconds) | DSL's own default | Default timeout for DSL commands that take `timeout:` |
| `scenarioTimeout` | int (seconds) | `90` | Host-side wall-clock timeout per scenario (watchdog). Distinct from `defaultTimeout`, which only bounds individual command waits |
| `machine` | string | auto-resolved | Explicit machine profile name (see the resolution order in [profiles.md](./profiles.md)) |
| `iosInappEngine` | bool | `true` | `true` → iOS devices run the hybrid engine (in-app primary, XCUITest fallback); `false` → XCUITest only. A device's own `engine` in the machine profile takes precedence if set. No effect on Android |
| `wipeDataOnBloat` | bool | `true` | At run start, wipe an Android AVD's data if the wipe-affected files (userdata/cache/snapshots) exceed `wipeDataThresholdGB` |
| `wipeDataThresholdGB` | number (GB) | `8` | Threshold for `wipeDataOnBloat` |
| `updateWebView` | bool | `true` | Reconcile the on-device WebView version at the start of a run, so the same scenario does not behave differently across devices with different WebView builds |
| `recoverCpuFallbackToGpu` | bool | `false` | At run start, restart any Android emulator that has fallen back to CPU rendering (swiftshader) in GPU mode instead |
| `locale` | string | `"ja_JP"` | Locale applied to an Android emulator on boot. No effect on iOS |
| `iosFastInput` | bool | `false` | Skip the quiescence wait on the iOS XCUITest bridge's text input (faster, but riskier on fast-moving screens). Only affects the XCUITest bridge |
| `containerInference` | bool | `true` | Enable geometry-based corrections that infer scroll containers (edge clamping, off-screen tap correction, etc.). Unrelated to FM |
| `enableAnimations` | bool | `false` | Keep the app's animations instead of disabling them for the run |
| `homeOnStart` | bool | `true` | Press Home once on every device at run start (works around devices staying black after a mass launch) |
| `record` | bool | `false` | Record each worker's screen for the whole run and cut it into a per-scenario clip |
| `recordFailuresOnly` | bool | `false` | With `record: true`, keep only clips for failed (including frozen) scenarios |
| `recordBitrateKbps` | int | `1500` | Re-encoding bitrate for saved clips |
| `recordFullResolution` | bool | `false` | With `record: true`, skip the half-resolution re-encode |
| `remoteControl` | object | — | Workspace declaration for remote execution (`{ "workspace": "<path>" }`); see [remote_runners.md](../in_action/remote_runners.md) |

## FM toggle hierarchy

`fm` is the parent switch; `heal` and `screenLooksLike` default to `true`, `falsePositiveCheck`
defaults to `false`. If `fm` is `false`, the individual toggles have no effect. Whether
self-healing is on by default also depends on how you invoke the run: **a `--profile` run
defaults `heal` to ON**, while a plain `ftester run` (no profile) defaults it to OFF. `--heal`
and `--no-heal` on the command line override either default (they cannot be combined).

## iOS engine

The effective iOS engine is `hybrid` (in-app primary, XCUITest fallback) by default —
`iosInappEngine: false` switches a run to XCUITest only. A physical iOS device always uses
XCUITest regardless of this setting (dylib injection is not available on physical devices).

## Deprecated key

`iosSystemAlertButtons` is no longer read. Use the scenario-level `iosAlertHandler` instead —
see [ios_alert_handler.md](../commands/ios_alert_handler.md).

### Link
- [index](../index.md)
