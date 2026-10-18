# Run profile settings

[in Japanese(日本語)](run_profile_ja.md)

`profiles/runs/<name>.json` combines an app, a device list and run-time settings. This page
lists every recognized key. See [profiles.md](./profiles.md) for the app profile it references
and how a device entry names its machine, and [running_scenarios.md](../running/running_scenarios.md)
for how `--profile` selects one.

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "Pixel 9(Android 16, API 36, APIs)-01", "avd": "Pixel_9_Android_16_API_36_APIs_-01" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `app` | string | — | Name of the `apps/<name>.json` profile to use. The run profile inherits that app profile's `platform` (target OS); `devices` of other OSes are ignored at run time ([profiles.md](./profiles.md)) |
| `devices` | array | — | Device entities to run (iOS/Android can mix in the same list). Each entry: `platform` (`"ios"`/`"android"`, required), `machine` (the machine it lives on — `"local"` for this Mac, or a name registered with `fleetest remote machines add`), `name` (required; unique together with `machine`; for an iOS Simulator this is the Simulator's own name), `enabled` (`false` keeps it listed but does not run it; default = run it), plus the device's own body keys (`osVersion`/`udid`/`avd`/`serial`/`kind`/`port`/`engine`/`model` — see [profiles.md](./profiles.md)) |
| `heal` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Allow selector self-healing (fingerprint matching; see [self_healing.md](../running/self_healing.md)). Independent of the FM- and OCR-based toggles below — self-healing does not use FM |
| `fmTextVisibilityCheck` | bool | `true` | Use FM (Foundation Models, experimental — see [environments.md](../../overview/environments.md)) for text visibility check. See [Text visibility check](../testclass/text_visibility_check.md). FM is called only when this or `screenLooksLike` is `true` |
| `screenLooksLike` | bool | `true` | Enable `screenLooksLike` (FM visual verification, experimental — see [environments.md](../../overview/environments.md)). When `false`, those steps are skipped rather than failing |
| `ocrTextVisibilityCheck` | bool | `true` | Use on-device OCR (Vision) for text visibility check. Independent of `fmTextVisibilityCheck`; the verification runs when either is `true` (and not at all when both are `false`). When FM gives no verdict, this reading alone decides. See [Text visibility check](../testclass/text_visibility_check.md) |
| `preferCheckStateClassifier` | bool | `true` | For `checkIsON` / `checkIsOFF`, prefer CheckStateClassifier (an image classifier trained from the sample images in the project's `vision/classifiers/CheckStateClassifier/[ON]` and `[OFF]`) over accessibility. When `false`, it is used only for elements whose accessibility reports no check state. It has no effect without sample images |
| `reportDir` | string | `"reports"` | Where to write Markdown reports (relative to the project root) |
| `defaultTimeout` | number (seconds) | `5` | Default timeout for DSL commands that take `waitSeconds:` |
| `scenarioTimeout` | int (seconds) | `600` | Host-side wall-clock timeout per scenario (watchdog). Distinct from `defaultTimeout`, which only bounds individual command waits. `@Test(scenarioTimeout:)` on a scenario overrides it for that scenario (even when shorter) Separately, a scenario whose output stops for longer than twice `commandTimeout` is stopped there (a slow scenario that keeps making progress is not). Also editable as "Scenario time limit (seconds)" under "Test execution" in the run profile on the monitor's Profiles tab |
| `iosInappEngine` | bool | `true` | `true` → iOS devices run the hybrid engine (in-app primary, XCUITest fallback); `false` → XCUITest only. A device's own `engine` in its `devices[]` entry takes precedence if set. No effect on Android |
| `wipeDataOnBloat` | bool | `true` | At run start, wipe an Android AVD's data if the wipe-affected files (userdata/cache/snapshots) exceed `wipeDataThresholdGB`. When installing the app fails because the device is out of storage, that device also gets a Wipe Data and the install is tried once more (with `false` the device is not wiped and drops out of the run) |
| `wipeDataThresholdGB` | number (GB) | `8` | Threshold for `wipeDataOnBloat` |
| `updateWebView` | bool | `true` | Reconcile the on-device WebView version at the start of a run, so the same scenario does not behave differently across devices with different WebView builds |
| `recoverCpuFallbackToGpu` | bool | `false` | At run start, restart any Android Emulator that has fallen back to CPU rendering (swiftshader) in GPU mode instead |
| `locale` | string | `"ja_JP"` | Locale applied to an Android Emulator on boot. No effect on iOS |
| `iosPreActionPing` | bool | `true` | On interop WebView screens (WebViews embedded by Compose/Flutter etc.), query the runner once right before each tap/type. An attached XCUITest session that has sat idle can report success while failing to deliver the coordinate event. Costs ~0.4s per event on those screens only (reads and other screens are unaffected). Only takes effect with the hybrid engine |
| `containerInference` | bool | `true` | Enable geometry-based corrections that infer scroll containers (edge clamping, off-screen tap correction, etc.). Unrelated to FM |
| `enableAnimations` | bool | `false` | Keep the app's animations instead of disabling them for the run |
| `responseMeasurement` | bool | `false` | **Experimental.** Response measurement mode for **one Android physical device** only. The profile must have exactly one enabled device, and it must be `kind: physical` and Android, otherwise the run is refused. The run keeps the app's animations (`enableAnimations` is forced on), turns off `fmTextVisibilityCheck`, `ocrTextVisibilityCheck`, `screenLooksLike`, `record` and host-load pacing, and holds the device monitor until the run ends. Setting `enableAnimations: false`, or any of the FM/OCR/`record` keys to `true`, together with it is an error. Cannot be combined with `--broadcast`, `--fleet` or `--split` |
| `responseRepeat` | int | `5` | **Experimental.** Only with `responseMeasurement: true` (specifying it without is an error). How many times each scenario runs back to back on the device, `2` to `50`. The first iteration only learns the next step's target and records no reaction time; the result files are named `<id>`, `<id>~2`, `<id>~3`, … |
| `homeOnStart` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Press Home once on every device at run start (works around devices staying black after a mass launch) |
| `playProtectBypass` | bool | `true` | Skips the Play Protect prompt ("Send app for a security check?") on Android `adb install` by turning "Verify apps over USB" off for the install and restoring it afterwards (the app is never sent to Google). `false` is the kill switch: the tool leaves the device setting alone, and a release-signed APK stays blocked on the device's own dialog (the tool never answers it) |
| `record` | bool | `true` | Record each worker's screen for the whole run and cut it into a per-scenario clip. A physical iPhone has no way to capture video, so its clip is a slideshow of the screen captured just before the first action and right after each action step and each failed step, shown at the time each was taken (each capture costs about 50 ms). Physical Android devices record normally. A Simulator, Emulator or physical Android device whose screen recording cannot start also switches to this slideshow, with a warning |
| `recordFailuresOnly` | bool | `false` | With `record: true`, keep only clips for failed (including frozen) scenarios |
| `recordBitrateKbps` | int | `1000` | Re-encoding bitrate for saved clips |
| `recordFullResolution` | bool | `false` | With `record: true`, skip the half-resolution re-encode. Test time does not change, but clip size and the wait for cutting clips after all tests finish go up, more so on screens with more motion |
| `remoteControl` | object | — | Workspace declaration (`{ "workspace": "<path>" }`). The workspace is always enabled and defaults to `TestProjects/<project>/workspace`. Even a local run stages the original `appPath` package here and reads `scripts/run-setup.sh` / `run-teardown.sh` and `scripts/compose.yaml` from it; see [Remote Runners](../../fleet/remote_runners.md) |

## FM usage

FM (Foundation Models) is called only when `fmTextVisibilityCheck` or `screenLooksLike` is `true`;
both default to `true`. When both are
`false`, FM is never called for that run — set both to `false` to keep a run from calling FM at
all. With `fmTextVisibilityCheck` set to `false`, the verification still runs on OCR alone while
`ocrTextVisibilityCheck` is `true` (FM is not called). `heal` does not use FM, so it is governed only by its own key.
Whether self-healing is on by default depends on how you invoke the run: **a `--profile` run
defaults `heal` to ON**, while a plain `fleetest run` (no profile) defaults it to OFF.
`fleetest run --profile <name> --set <key>=<value>` overrides almost any key on this table for one
run without editing the profile file — e.g. `--set heal=false`, `--set fmTextVisibilityCheck=false`,
`--set reportDir=/tmp/out`, `--set defaultTimeout=8` (the value must match the
key's type shown above; repeatable). It works with or without `--profile` — except the keys that need a run
profile's device list or supply pipeline (`iosInappEngine`, `updateWebView`, `wipeDataOnBloat`,
`recoverCpuFallbackToGpu`, `app`, `locale`, `wipeDataThresholdGB`, `responseMeasurement`, `responseRepeat`), which require
`--profile`. `devices` and `remoteControl` are a list and an object and cannot be expressed as
`<key>=<value>`; edit the profile JSON for those. `record` needs either `--profile` or `--port` given more than once (a single connection has no recording session to attach to). `reportDir` cannot be combined with `--report-dir` (same field, two ways to set it). The run profile key `app` names an app **profile**, unrelated to `fleetest run`'s `--app-id` flag. An unknown key or a value of the wrong type passed to `--set` is an error
(an unknown key inside the profile JSON only prints a warning and is ignored).

## iOS engine

The effective iOS engine is `hybrid` (in-app primary, XCUITest fallback) by default —
`iosInappEngine: false` switches a run to XCUITest only. A physical iOS device always uses
XCUITest regardless of this setting (dylib injection is not available on physical devices).

### Link
- [index](../../index.md)
