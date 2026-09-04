# Profiles

A run is configured from three kinds of JSON profile under `TestProjects/<name>/profiles/`,
combined by reference rather than by inheritance:

| Kind | File | Purpose |
|---|---|---|
| App profile | `apps/<name>.json` | The app under test (bundle ID / package, build path) |
| Machine profile | `machines/<machine name>.json` | The devices available on one machine |
| Run profile | `runs/<name>.json` | Which app + which devices + run-time settings (see [run_profile.md](./run_profile.md)) |

## App profiles

`apps/<name>.json` merges a `common` section with an `ios`/`android` section (the OS-specific
section wins on conflicts):

```json
{ "common":  { "autoInstall": true },
  "ios":     { "appName": "Sample App", "app": "com.example.sampleapp",
               "appPath": "~/builds/SampleApp.app" },
  "android": { "appName": "Sample App", "app": "com.example.sampleapp",
               "appPath": "builds/app-debug.apk" } }
```

- `autoInstall` is only read from `common` (default: whether `appPath` is set — write `false`
  explicitly to opt out even with a path present).
- `appName` (display name), `app` (bundle ID / package) and `appPath` are only read from the
  `ios`/`android` sections (writing them in `common` is ignored, so the display name can differ
  per OS).
- `appPath` is relative to the repository root by default (`~` and absolute paths also work).
  Android accepts `.apk` or `.apks` (an App Bundle split set; installing `.apks` requires
  `bundletool`).
- `healthCheckURL` (in `common`, optional): a backend URL checked at the start of a run
  (3-second timeout, warns but does not block).

## Machine profiles

`machines/<machine name>.json` — the file name is the machine name. One file lists every device
this machine can use, under `ios` and `android`:

```json
{ "ios":     { "devices": [ { "name": "simulator1", "simulator": "iPhone 17 Pro", "os": "27.0" } ] },
  "android": { "devices": [ { "name": "emulator1", "avd": "Pixel 9(Android 16)" } ] } }
```

- Device names must be unique within one file (across both `ios` and `android`).
- A physical device sets `"kind": "physical"` and an identifier instead of a simulator/AVD
  reference — iOS uses `udid` (from `xcrun devicectl list devices`, the `hardwareProperties.udid`
  form), Android uses `serial` (the left column of `adb devices`):

```json
{ "ios":     { "devices": [ { "name": "iPhone (physical)", "kind": "physical",
                              "udid": "00008130-000A1B2C3D4E5678" } ] },
  "android": { "devices": [ { "name": "Pixel (physical)", "kind": "physical",
                              "serial": "14141JEC204922" } ] } }
```

- **Turn auto-lock off on physical devices.** On iOS: Settings → Display & Brightness →
  Auto-Lock → **Never**. On Android: Settings → Display → Screen timeout, set it long enough.
  **The tool does not keep the screen awake** — if the screen sleeps during a step that waits,
  the OS refuses every later app launch and the run stops. Starting against a locked device is
  refused by name (unlocking it automatically is impossible: the only thing that can send input
  to the device is the runner on that device, and it is not running yet).
- A device's `host` can name a registered remote machine, so the run is dispatched to it over
  SSH instead of running locally (see [remote_runners.md](../in_action/remote_runners.md)).
  Leaving `host` unset means "this machine".

`fleetest profile setup --auto-device` picks a device automatically: for iOS, the newest-OS
existing simulator (excluding iPads); for Android, the existing AVD with the highest API level.

## Machine resolution order

1. The run profile's `machine` key.
2. The `FT_MACHINE` environment variable.
3. If `machines/` has exactly one file, that one.
4. Otherwise, an error listing the candidate machine names.

A device `name` listed in a run profile but not defined on the current machine is skipped with a
warning, rather than failing the run — this is what lets one run profile be reused across
machines.

## Commands

| Command | Description |
|---|---|
| `fleetest profile setup --platform <ios\|android\|both> --app-id <id> [--auto-device] [...]` | Create/refresh the app, machine and run profiles together (idempotent) |
| `fleetest profile list` | List run profiles and show how they resolve on this machine |

## Editing in VS Code

The VS Code extension's Device tab lets you edit run/app/machine profiles interactively, and
`profiles/{apps,machines,runs}/*.json` get a JSON schema (`schemas/*.schema.json`) contributed by
the extension for completion, hover and structural validation while editing by hand. See
the "実行プロファイルの編集支援" section of
[vscode-fleetest/README.md](../../../vscode-fleetest/README.md) (Japanese).

### Link
- [index](../index.md)
