# Machine settings (config.json)

[in Japanese(日本語)](machine_settings_ja.md)

All keys you can put in `~/.config/fleetest/config.json` on the Mac that runs scenarios. Each key is listed with its
type, default, meaning and the page that covers it in detail.

- **Settings live only on the Mac that runs the scenarios.** They cannot be overridden from a project or a
  [run profile](run_profile.md). The sandbox and `hooks` settings cannot be redirected to another file with `XDG_CONFIG_HOME`
  either (so that a scenario side cannot loosen the walls). Keys for which an environment variable takes priority are
  marked in the table below.
- **The person at this Mac writes it by hand.** When fleetest is installed, Claude Code gets a deny rule
  `Edit(~/.config/fleetest/**)` (because things such as `sandbox.disabled`, which removes the sandbox, live here). The rule
  is not written when the work folder is inside the fleetest clone. You can ask an AI assistant to read the file and
  explain it, but make the edits yourself.
- **An unknown key or broken JSON stops with an error before the scenario starts.** It stops for an unknown key inside
  the `sandbox`, `hooks` or `services` section, and when the file as a whole is not valid JSON (so that a restriction you
  added is never silently dropped). For example, `"sandbox": { "allowedDomain": [...] }` (a missing `s`) is caught as an error.
- **Settings take effect from the next scenario launch.** No restart is needed.

## Example

```json
{
  "sandbox": {
    "allowedDomains": ["api.example.com:443"],
    "denyRead": ["~/work/secrets"],
    "allowDirectAdb": false,
    "disabled": false
  },
  "hooks": {
    "writablePaths": ["~/work/shared-fixtures"]
  },
  "services": {
    "runtime": "docker",
    "buildSources": ["/Users/me/work/server-src"],
    "publishForPhysicalDevices": "192.168.1.10"
  },
  "redactAccountValues": true
}
```

## All keys

| Key | Type | Default | Meaning | Details |
|---|---|---|---|---|
| `sandbox.allowedDomains` | array of strings | none (scenarios cannot reach the outside at all) | External destinations scenarios may reach (`api.example.com:443`, `*.example.org`) | [Sandbox defaults](../running/sandbox_access.md), [Network access from scenarios](../writing/network_access.md) |
| `sandbox.denyRead` | array of strings | none | Places **added** to the built-in unreadable list (it does not replace it; `~` is accepted) | [Sandbox defaults](../running/sandbox_access.md) |
| `sandbox.allowDirectAdb` | boolean | `false` | When `true`, scenarios can use adb and bundletool themselves. In exchange they can reach the outside through the shell inside an Emulator and reach every connected Android device | [Checking the sandbox and opening the holes you need](../../security/sandbox.md) |
| `sandbox.disabled` | boolean | `false` | When `true`, the sandbox is removed on this Mac | [Checking the sandbox and opening the holes you need](../../security/sandbox.md) |
| `hooks.writablePaths` | array of strings | none (only `<workspace>/data/`) | Extra places `run-setup.sh` / `run-teardown.sh` may write (absolute paths or paths starting with `~/`) | [Running scripts before and after a run](../writing/extending.md#running-scripts-before-and-after-a-run) |
| `services.runtime` | `"docker"` or `"apple"` | unset | The container runtime for compose.yaml services. When unset, fleetest looks for a usable one and uses it if exactly one is usable. If both are usable it stops with an error instead of picking silently, so name one on that Mac | [Services the app depends on](../writing/services.md) |
| `services.buildSources` | array of strings | none | Places allowed as a `build:` context in addition to under `scripts/` (absolute paths; `~` is not expanded; mounted read-only for the build) | [Services the app depends on](../writing/services.md) |
| `services.publishForPhysicalDevices` | string (IPv4) | none | Your consent to bind the services' published ports on every interface for a run that includes a physical device. Set it to this Mac's LAN IPv4 address; the device reaches the services at that address | [Services the app depends on](../writing/services.md), [Measuring app responsiveness](../../response/measuring_app_response.md) |
| `redactAccountValues` | boolean | `false` (not redacted) | When `true`, values from `account()` are replaced with `***` in reports, run logs and results JSON | [Test data and accounts](../commands/dataset.md) |
| `hostLoadPacing` | object | enabled (no `disabled`) | The "step pacing": one short wait before an operation that changes the screen, at moments when the Mac's CPU load is high. `disabled: true` turns it off; `tiers` (an array of `cpuPercentAtLeast` and `delayMs` pairs) changes the steps | [Parallel execution](../running/parallel_execution.md) |
| `hostLoadPacing.tiers` | array | 200 ms at CPU 90% or more, 1000 ms at 95% or more | An empty array `[]` means "no tiers = never wait". With invalid values it runs with the default tiers and prints one warning at the start of the run | [Parallel execution](../running/parallel_execution.md) |
| `retention` | object | see the table below | Retention caps for logs, recordings, reports and so on. A missing section means "all defaults", not "never clean up" | [Maintenance for long-term use](../../in_action/maintenance.md), [VSCode extension](../tools/vscode_extension.md) |
| `remoteHosts` | array | none | The registry of runner machines for remote runs (`machine`, `host`, `dir`, `fmConcurrency`, `color`, `enabled`, `developerDir`) | [Adding a Mac](../../fleet/adding_mac.md), [Remote runners](../../fleet/remote_runners.md) |
| `developmentTeam` | string | none (physical iOS devices cannot be built) | The Apple Developer Team ID used to sign the physical-iOS-device bridge. The environment variable `FT_DEVELOPMENT_TEAM` takes priority | [Adding physical devices](../../fleet/adding_physical_devices.md) |
| `bundleIDPrefix` | string | `com.example` | The prefix of the bundle id of the physical-iOS-device bridge. Use a value no other team uses. The environment variable `FT_BUNDLE_ID_PREFIX` takes priority | [Adding physical devices](../../fleet/adding_physical_devices.md) |
| `issuerId` | string | `user name@host name` | A self-declared name that records "who started this" for remote runs (not authentication). The environment variable `FT_ISSUER` takes priority | [Remote runners](../../fleet/remote_runners.md), [Adding physical devices](../../fleet/adding_physical_devices.md) |
| `fmConcurrency` | integer | `1` | How many Apple Intelligence (Foundation Models) calls **this Mac** makes at once. An integer of 1 or more. The environment variable `FT_FM_CONCURRENCY` takes priority. For a remote runner machine, put it in that machine's registration (`fmConcurrency` in `remoteHosts`) | The basis for tuning is in the maintainer document `docs/performance-tuning.md` |
| `defaultProject` | string | none | The project name used when `--project` is omitted. It follows project renames and removals (`fleetest project`) automatically | [Creating a Test Project](creating_project.md) |
| `lastRunProfile` | object (project name → run profile name) | none | Where the extension remembers the run profile it last selected. **The extension writes it; do not edit it by hand** | — |
| `localMachineEnabled` | boolean | `true` | "Machine enabled" for this Mac's row in the extension's Settings tab. Only `false` is stored. **The extension writes it; do not edit it by hand** | [VSCode extension](../tools/vscode_extension.md) |

### What `retention` contains

Values are in bytes and are the cap for the whole category (not per run or per day). When usage exceeds 90% of a cap,
the oldest items are removed down to 90%. You can also change them from "Logs and recordings" in the extension's
Settings tab.

| Key | Default | Covers |
|---|---|---|
| `deviceCapturesMaxBytes` | 2 GiB | Attachments the Simulator's test runs leave |
| `recordingsMaxBytes` | 50 GiB | Run recordings |
| `eventLogsMaxBytes` | 2 GiB | Per-scenario run logs |
| `reportsMaxBytes` | 2000 MiB | The project's `reports/` (Markdown and screenshots) |
| `logsMaxBytes` | 100 MiB | `.fleetest/*.log`, such as the bridge logs |
| `xcresultMaxBytes` | 5 GiB | The result bundles of the XCUITest runner |
| `sweepAfterRun` | `true` | Whether to clean up in the background after a run finishes |

There are minimums, and a smaller cap is not accepted (`deviceCapturesMaxBytes` 1 GiB, `recordingsMaxBytes` 2 GiB,
`eventLogsMaxBytes` 100 MiB, `reportsMaxBytes` 100 MiB, `logsMaxBytes` 10 MiB, `xcresultMaxBytes` 1 GiB).

### Link
- [index](../../index.md)
