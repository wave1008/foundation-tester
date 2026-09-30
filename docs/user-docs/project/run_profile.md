# Run Profile Keys

`profiles/runs/<name>.json` combines an app, a device list and run-time settings. This page
lists every recognized key. See [profiles.md](./profiles.md) for the app profile it references
and how a device entry names its machine, and [running_scenarios.md](../running/running_scenarios.md)
for how `--profile` selects one.

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "emulator1", "avd": "Pixel 9(Android 16)" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `app` | string | — | Name of the `apps/<name>.json` profile to use |
| `devices` | array | — | Device entities to run (iOS/Android can mix in the same list). Each entry: `platform` (`"ios"`/`"android"`, required), `machine` (the machine it lives on — `"local"` for this Mac, or a name registered with `fleetest remote machines add`), `name` (required; unique together with `machine`; for an iOS simulator this is the simulator's own name), `enabled` (`false` keeps it listed but does not run it; default = run it), plus the device's own body keys (`osVersion`/`udid`/`avd`/`serial`/`kind`/`port`/`engine`/`model` — see [profiles.md](./profiles.md)) |
| `heal` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Allow selector self-healing (fingerprint matching; see [self_healing.md](../running/self_healing.md)). Independent of the FM- and OCR-based toggles below — self-healing does not use FM |
| `fmTextOcclusionCheck` | bool | `true` | Use FM (Foundation Models, experimental — see [environments.md](../overview/environments.md)) in text visual verification (occlusion guard) on `exist`/`textIs` etc., which catches a "false green" that matched in the tree but is not actually visible. Independent of `ocrTextOcclusionCheck`; the verification runs when either is `true`. When both are `true`, FM is skipped only for elements OCR reads in full; everything else is judged by both OCR and FM, and the step passes if either reads the expected text. When this is `false`, the OCR reading alone decides. FM is called only when this or `screenLooksLike` is `true` |
| `screenLooksLike` | bool | `true` | Enable `screenLooksLike` (FM visual verification). When `false`, those steps are skipped rather than failing |
| `ocrTextOcclusionCheck` | bool | `true` | Use on-device OCR (Vision) in text visual verification. Independent of `fmTextOcclusionCheck`; the verification runs when either is `true`. When the expected text is read in full the step passes without an FM call. When `fmTextOcclusionCheck` is `false`, or FM gives no verdict (macOS 26, or FM failing), this reading alone decides and fails a step whose element it reads as not visible. Turning this off makes the check slower and drops that fallback (with `fmTextOcclusionCheck` also `false`, the verification does not run at all). Even when off, OCR still re-reads the element when FM's transcript differs from the expected text by a single character, so a misread glyph (such as a Japanese kanji read as its Simplified Chinese form) does not fail the step (that step may take up to 60 s the first time while OCR prepares). |
| `preferCheckStateClassifier` | bool | `true` | For `checkIsON` / `checkIsOFF`, prefer CheckStateClassifier (an image classifier trained from the sample images in the project's `vision/classifiers/CheckStateClassifier/[ON]` and `[OFF]`) over accessibility. When `false`, it is used only for elements whose accessibility reports no check state. It has no effect without sample images |
| `reportDir` | string | `"reports"` | Where to write Markdown reports (relative to the project root) |
| `defaultTimeout` | number (seconds) | DSL's own default | Default timeout for DSL commands that take `waitSeconds:` |
| `scenarioTimeout` | int (seconds) | `90` | Host-side wall-clock timeout per scenario (watchdog). Distinct from `defaultTimeout`, which only bounds individual command waits |
| `iosInappEngine` | bool | `true` | `true` → iOS devices run the hybrid engine (in-app primary, XCUITest fallback); `false` → XCUITest only. A device's own `engine` in its `devices[]` entry takes precedence if set. No effect on Android |
| `wipeDataOnBloat` | bool | `true` | At run start, wipe an Android AVD's data if the wipe-affected files (userdata/cache/snapshots) exceed `wipeDataThresholdGB`. When installing the app fails because the device is out of storage, that device also gets a Wipe Data and the install is tried once more (with `false` the device is not wiped and drops out of the run) |
| `wipeDataThresholdGB` | number (GB) | `8` | Threshold for `wipeDataOnBloat` |
| `updateWebView` | bool | `true` | Reconcile the on-device WebView version at the start of a run, so the same scenario does not behave differently across devices with different WebView builds |
| `recoverCpuFallbackToGpu` | bool | `false` | At run start, restart any Android emulator that has fallen back to CPU rendering (swiftshader) in GPU mode instead |
| `locale` | string | `"ja_JP"` | Locale applied to an Android emulator on boot. No effect on iOS |
| `iosFastInput` | bool | `false` | Skip the quiescence wait on the iOS XCUITest bridge's text input (faster, but riskier on fast-moving screens). Only affects the XCUITest bridge |
| `iosPreActionWarmup` | bool | `true` | On interop WebView screens (WebViews embedded by Compose/Flutter etc.), query the runner once right before each tap/type. An attached XCUITest session that has sat idle can report success while failing to deliver the coordinate event (measured ~13% → 0/50 with the warm-up). Costs ~0.4s per event on those screens only (reads and other screens are unaffected). Only takes effect with the hybrid engine |
| `containerInference` | bool | `true` | Enable geometry-based corrections that infer scroll containers (edge clamping, off-screen tap correction, etc.). Unrelated to FM |
| `sandbox` | bool | `false` | Run the process that executes your scenarios inside macOS Seatbelt (experimental). See "Scenario sandbox" below |
| `sandboxConfig` | string | — | Location of the sandbox configuration file, relative to the test project root. When omitted, `sandbox.json` is read if it exists |
| `enableAnimations` | bool | `false` | Keep the app's animations instead of disabling them for the run |
| `homeOnStart` | bool | `true` for `--profile` runs, `false` for a plain `fleetest run` | Press Home once on every device at run start (works around devices staying black after a mass launch) |
| `playProtectBypass` | bool | `true` | Skips the Play Protect prompt ("Send app for a security check?") on Android `adb install` by turning "Verify apps over USB" off for the install and restoring it afterwards (the app is never sent to Google). `false` is the kill switch: the tool leaves the device setting alone, and a release-signed APK stays blocked on the device's own dialog (the tool never answers it) |
| `record` | bool | `false` | Record each worker's screen for the whole run and cut it into a per-scenario clip. Physical iPhones cannot be recorded (no `simctl io recordVideo`): the run warns for that worker and saves no clip. Physical Android devices record normally |
| `recordFailuresOnly` | bool | `false` | With `record: true`, keep only clips for failed (including frozen) scenarios |
| `recordBitrateKbps` | int | `1500` | Re-encoding bitrate for saved clips |
| `recordFullResolution` | bool | `false` | With `record: true`, skip the half-resolution re-encode |
| `remoteControl` | object | — | Workspace declaration for remote execution (`{ "workspace": "<path>" }`); see [remote_runners.md](../in_action/remote_runners.md) |

## FM usage

FM (Foundation Models) is called only when `fmTextOcclusionCheck` or `screenLooksLike` is `true`;
both default to `true` (`fmTextOcclusionCheck` changed from opt-in on 2026-09-03). When both are
`false`, FM is never called for that run — set both to `false` to keep a run from calling FM at
all. With `fmTextOcclusionCheck` set to `false`, the verification still runs on OCR alone while
`ocrTextOcclusionCheck` is `true` (FM is not called). `heal` does not use FM, so it is governed only by its own key.
Whether self-healing is on by default depends on how you invoke the run: **a `--profile` run
defaults `heal` to ON**, while a plain `fleetest run` (no profile) defaults it to OFF.
`fleetest run --profile <name> --set <key>=<value>` overrides almost any key on this table for one
run without editing the profile file — e.g. `--set heal=false`, `--set fmTextOcclusionCheck=false`,
`--set reportDir=/tmp/out`, `--set defaultTimeout=8` (see
[running_scenarios.md](../running/running_scenarios.md) for `--set`; the value must match the
key's type shown above). It works with or without `--profile` — except the keys that need a run
profile's device list or supply pipeline (`iosInappEngine`, `updateWebView`, `wipeDataOnBloat`,
`recoverCpuFallbackToGpu`, `app`, `locale`, `wipeDataThresholdGB`), which require
`--profile`. `devices` and `remoteControl` are a list and an object and cannot be expressed as
`<key>=<value>`; edit the profile JSON for those. An unknown key passed to `--set` is an error
(an unknown key inside the profile JSON only prints a warning and is ignored).

## Scenario sandbox

With `sandbox: true`, the process that executes your scenarios (the Swift code you wrote) runs
inside macOS Seatbelt (`sandbox-exec`). fleetest itself — device provisioning, builds, the
monitor — is not sandboxed. The feature is experimental and defaults to `false`.

The sandbox starts from "deny everything" and opens only the following.

| Area | Allowed |
|---|---|
| Writes | Only the report directory (`reportDir`), the `.fleetest/` directories of the project and the repository root, `~/.fleetest/`, temporary directories, fleetest's own caches and logs, and the data containers of apps on simulators (used by `clearAppData`) |
| Reads | The locations listed in `denyRead` of the configuration file are unreadable. Everything else is readable |
| Network | Only this Mac (bridges, adb, emulators). External hosts are reachable only when listed in `allowedDomains` of the configuration file, through a proxy that fleetest runs |
| Simulator operations | A scenario cannot operate the simulator directly. fleetest performs the operations on its behalf and accepts only a fixed set (launch, terminate, install, open URL, clear data and so on) |
| Everything else | Launching applications (`open`), instructing other processes and connecting to system services are not possible |

### Configuration file

Unreadable locations and allowed destinations are written in JSON. The run profile's
`sandboxConfig` gives its location, relative to the test project root. When it is omitted,
`sandbox.json` in the project root is read if it exists.

```json
{
  "denyRead": ["~/.ssh", "~/.aws", "~/Documents", "secrets"],
  "allowedDomains": ["api.example.com", "*.example.net"]
}
```

- `denyRead`: Locations the scenario cannot read. `~` and paths relative to the project are accepted. **Writing it replaces the default list** (the default is `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.kube`, `~/.docker`, `~/.config/gh` and `~/Library/Keychains`)
- `allowedDomains`: Destinations allowed for external traffic. `api.example.com` matches exactly; `*.example.net` matches subdomains (not `example.net` itself). When omitted or empty, nothing external is reachable. A bare `*` is not accepted

An unknown key or a malformed domain stops the run with an error before anything starts (it is
not silently ignored).

Traffic to `allowedDomains` goes through a proxy that fleetest starts. Its location is passed in
environment variables (`HTTPS_PROXY` and friends), so only clients that honour those variables
(such as `curl`) get through. `URLSession` does not read proxy environment variables; to use it
from a scenario, pass the value of `HTTPS_PROXY` to `connectionProxyDictionary`.

### What is covered

| Operation | The sandbox applies when |
|---|---|
| `fleetest run --profile <name>` | The profile has `sandbox: true`, or `--set sandbox=true` is given |
| `fleetest run --dry-run` | Same as above (`--dry-run` uses only `sandbox` and `sandboxConfig` from the profile) |
| The step list and the scenario list in the extension | The run profile selected in the extension has `sandbox: true` |
| Any of the above, regardless of the profile | The machine-level setting `~/.config/fleetest/config.json` has `"sandboxRequired": true` |

The Swift code of a scenario can execute during a dry run and while listing scenarios, so those
are wrapped in the same sandbox.

### What it prevents and what it does not

**Prevented**: scenario code modifying files outside the project, reading the locations you
listed, connecting directly to external hosts, or launching another application or command
outside the sandbox.

**Not prevented**:

- **Connections to services on this Mac.** A scenario connects to the bridges and adb to drive
  devices, so other services listening on localhost are reachable too.
- **Data leaving through the device.** A scenario can send the contents of any file it can read
  as input to an app or a browser. List the locations you do not want read in `denyRead`.
- **What the app under test does.** The app runs inside the simulator, as a process outside the
  sandbox.
- **Changes to the settings.** The run profile and the configuration file live inside the
  project, so anyone who can modify the project can change `sandbox` and the lists. To keep the
  sandbox from being turned off, use `sandboxRequired`, which lives outside the project, and keep
  the configuration file somewhere that cannot be modified.

### Notes

- In a run with the sandbox on, each scenario's log starts with a `🔒 sandbox: …` line.
- An operation the sandbox refuses fails with `Operation not permitted`; a simulator operation
  that fleetest refuses fails with `sandbox: refused`.
- On a physical iOS device, the operations used to reinstall and launch apps (`devicectl`) are
  not available from inside the sandbox.
- `sandbox-exec` is a command Apple has deprecated. Its behaviour may change with macOS updates.

## iOS engine

The effective iOS engine is `hybrid` (in-app primary, XCUITest fallback) by default —
`iosInappEngine: false` switches a run to XCUITest only. A physical iOS device always uses
XCUITest regardless of this setting (dylib injection is not available on physical devices).

### Link
- [index](../index.md)
