# Profiles

A run is configured from two kinds of JSON profile under `TestProjects/<name>/profiles/`,
combined by reference rather than by inheritance:

| Kind | File | Purpose |
|---|---|---|
| App profile | `apps/<name>.json` | The app under test (bundle ID / package, build path) |
| Run profile | `runs/<name>.json` | Which app + which devices (each naming the machine it lives on) + run-time settings (see [run_profile.md](./run_profile.md)) |

## App profiles

`apps/<name>.json` has top-level keys (`platform`, `autoInstall`, `healthCheckURL`) plus an
`ios` and an `android` section:

```json
{ "platform": "hybrid",
  "autoInstall": true,
  "ios":     { "appName": "Sample App", "app": "com.example.sampleapp",
               "appPath": "~/builds/SampleApp.app" },
  "android": { "appName": "Sample App", "app": "com.example.sampleapp",
               "appPath": "builds/app-debug.apk" } }
```

- `platform` (optional): `"ios"`, `"android"` or `"hybrid"` — the OS(es) the app runs on. `hybrid` means
  both, and omitting the key means the same (saving from the VS Code extension's Profiles tab writes
  `hybrid` explicitly too). Devices of an OS the app does not target are **ignored at run time**
  (each one is reported as a warning; the run profile's JSON is not changed). A run whose devices are
  all ignored fails with an error naming the app profile.
- `autoInstall` is a top-level key (default: whether `appPath` or `appPathPhysical` is
  set — write `false` explicitly to opt out even with a path present).
- `appName` (display name), `app` (bundle ID / package) and `appPath` are only read from the
  `ios`/`android` sections, so the display name can differ per OS.
- `appName` must be exactly the name shown under the app icon on the home screen: `tapAppIcon()`
  without a name looks for it, and a system alert is attributed to your app by it. Do not add a
  suffix to tell profiles apart (e.g. "(device)"). On iOS, a run (and `api validate-profile`)
  warns when it matches none of the app bundle's display names read from `appPath`
  (`CFBundleDisplayName`, falling back to `CFBundleName`; localized names also count).
- `appPath` is relative to the repository root by default (`~` and absolute paths also work).
  Android accepts `.apk` or `.apks` (an App Bundle split set; installing `.apks` requires
  `bundletool`). iOS `appPath` is a `.app` (Simulators install nothing else); `appPathPhysical`
  may be a `.app` or an `.ipa`.
- The tool also reads the app's UI framework from that package (Compose Multiplatform / Flutter /
  everything else) to decide whether a scroll needs a relief gesture before the next tap, and
  remembers the answer per bundle ID. When neither the package nor a remembered answer is at hand
  (an app installed on a physical device by other means), the decision is made per element from the
  accessibility tree (custom-drawn elements, as Compose / Flutter expose them, get the gesture; view-backed
  ones do not) and the run says so once. Point `appPath` / `appPathPhysical` at the package once to
  settle it for good.
- `healthCheckURL` (top-level, optional): a backend URL checked at the start of a run
  (3-second timeout, warns but does not block).

## Devices

A run profile's `devices` array lists the device entities the run uses. Each entry says which
machine it lives on and gives it a name that is unique together with that machine, so the same
name can exist on different machines and the same device can appear — independently toggled with
`enabled` — in more than one run profile. See [run_profile.md](./run_profile.md) for the full key
list and every run-time setting.

```json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "M1Max", "name": "Pixel 9(Android 16, API 36, APIs)-01", "avd": "Pixel_9_Android_16_API_36_APIs_-01" },
    { "platform": "android", "machine": "local", "name": "Pixel 8(Android 14, API 34, APIs)-01", "enabled": false, "avd": "Pixel_8_Android_14_API_34_APIs_-01" }
  ],
  "heal": true }
```

- `machine` is `"local"` for a device on this Mac, or the name of a machine registered with
  `fleetest remote machines add`, which dispatches that device's run over SSH instead of running
  it locally (see [remote_runners.md](../../in_action/remote_runners.md)).
- For an iOS Simulator, `name` is the Simulator's own name (Xcode's **Name**, i.e. the simctl
  name) and `osVersion` is Xcode's **OS Version** (e.g. `"iOS 27.0"`) — together they are how fleetest finds
  the Simulator when `udid` is absent. `model` (Xcode's **Model**) is display-only. See
  [run_profile.md](./run_profile.md) for the full key list.
- A physical device sets `"kind": "physical"` and an identifier instead of a Simulator/AVD
  reference — iOS uses `udid` (from `xcrun devicectl list devices`, the `hardwareProperties.udid`
  form), Android uses `serial` (the left column of `adb devices`):

```json
{ "platform": "ios", "machine": "local", "name": "iPhone (physical)", "kind": "physical",
  "udid": "00008130-000A1B2C3D4E5678" }
```

- **Turn auto-lock off on physical devices.** On iOS: Settings → Display & Brightness →
  Auto-Lock → **Never**. On Android: Settings → Display → Screen timeout, set it long enough.
  **The tool does not keep the screen awake** — if the screen sleeps during a step that waits,
  the OS refuses every later app launch and the run stops. Starting against a locked device is
  refused by name (unlocking it automatically is impossible: the only thing that can send input
  to the device is the runner on that device, and it is not running yet).

`fleetest profile setup --auto-device` picks a device automatically: for iOS, the newest runtime of the
selected Xcode (installed with `xcodebuild -downloadPlatform iOS` when missing: several GB, several minutes to
tens of minutes) and the newest plain `iPhone <N>` it supports (Pro, Pro Max, Plus, Air, e, mini and SE variants are excluded); for Android, the newest `Pixel <N>` or `Pixel <N>a` (the plain one wins a tie; Pro, Fold and other variants are excluded) with the
`google_apis` system image of the highest API level. The VSCode extension's "Add device" dialog also opens
with the same combination pre-selected.

## Commands

| Command | Description |
|---|---|
| `fleetest profile setup --platform <ios\|android\|both> --app-id <id> [--auto-device] [...]` | Create/refresh the app and run profiles together (idempotent) |
| `fleetest profile list` | List run profiles and their devices |

## Editing in VS Code

The VS Code extension's Profiles tab lets you edit run/app profiles interactively — the run
profile section shows the union of every run profile's devices, with checkboxes selecting which
ones this run profile runs — and `profiles/{apps,runs}/*.json` get a JSON schema
(`schemas/*.schema.json`) contributed by the extension for completion, hover and structural
validation while editing by hand. See the "実行プロファイルの編集支援" section of
[vscode-fleetest/README.md](../../../../vscode-fleetest/README.md) (Japanese).

### Link
- [index](../../index.md)
