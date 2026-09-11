# Running Scenarios

`fleetest run` executes Swift DSL scenarios deterministically (no FM involved unless a step
fails and self-healing or triage is enabled). This page covers the CLI options; see
[dry_run.md](./dry_run.md) for `--dry-run` and [self_healing.md](./self_healing.md) for
enabling self-healing with `--set`.

## Invoking the CLI

```bash
# Clone configuration (working inside the foundation-tester clone)
swift run fleetest run --profile ios

# External package configuration (a separate work folder with TestProjects/)
../foundation-tester/.build/debug/fleetest run --profile ios
```

## Common options

| Option | Description |
|---|---|
| `--project <project>` | Test project name (see [creating_project.md](../project/creating_project.md) for the resolution order when omitted) |
| `--profile <profile>` | Run profile name (`profiles/runs/<name>.json`). Includes device provisioning and auto-install. **Cannot be combined with `--platform`/`--port`/`--serial`/`--app-id`** (the profile supplies all of those) — combining them is an error, not a silent override |
| `--scenario <id>` | Scenario ID: a class name alone runs every scenario in it, or `Class.method` for one. Repeatable; defaults to all. `@Deleted`/`@Draft` scenarios only run on an exact match |
| `--folder <folder>` | Scenario folders to run (subfolders directly under `scenarios/`). Repeatable; combinable with `--scenario`/`--failed` |
| `--failed` | Run only the scenarios that failed last time. Results are recorded per `(project, profile)` in `.fleetest/last-results/` on every run — a scenario that failed under one run profile is not hidden by a green run of a different profile, and a profile-less run has its own bucket. `--failed` looks at the profile you pass to this same invocation (or the profile-less bucket if you omit `--profile`) |
| `--set <key>=<value>` | Override one run profile key for this run only, using the exact key name from the profile JSON and a value matching that key's type — `true`/`false` for a boolean key (e.g. `heal`, `falsePositiveCheck`, `ocr`, `enableAnimations`, `iosFastInput`), or a string/number for a scalar key (e.g. `--set reportDir=/tmp/out`, `--set defaultTimeout=8`). All keys are listed in [run_profile.md](../project/run_profile.md). Repeatable; works with or without `--profile`, except the keys that need a run profile's device list or supply pipeline (`iosInappEngine`, `updateWebView`, `wipeDataOnBloat`, `recoverCpuFallbackToGpu`, `app`, `machine`, `locale`, `wipeDataThresholdGB`), which name the key in the error when `--profile` is missing. `record` also needs either `--profile` or `--port` given more than once (a single connection has no recording session to attach to). `reportDir` cannot be combined with `--report-dir` (same field, two ways to set it — pick one). The run profile keys `app`/`machine` name an app/machine **profile**, unrelated to this command's own `--app-id`/`--runner` flags. `devices`/`remoteControl` are lists/objects and cannot be set this way; edit the run profile JSON instead. An unknown key, a value of the wrong type, or a list/object key is an error that explains what to do instead |
| `--dry-run` | Validate steps without touching a device (see [dry_run.md](./dry_run.md)) |
| `--report-dir <dir>` | Directory to write reports to (default: `TestProjects/<name>/reports`). Cannot be combined with `--set reportDir=...` |
| `--port <port>` | Bridge port for manual parallel iOS runs. Repeatable (`--port 8123 --port 8124`; see [parallel_execution.md](./parallel_execution.md)) |
| `--skip-build` | Skip the `swift build` before running |
| `--quiet` | Print only the summary (for CI and agents) |
| `--junit <path>` | Write a JUnit XML report to this path |
| `--broadcast` | Run the selected scenarios once on **every** device of the run profile, instead of sharing them out (e.g. a warm-up). Requires `--profile`; results are told apart by their `worker` field (see [results_analysis.md](./results_analysis.md)) |
| `--no-lpt` | Disable LPT ordering (longest-past-runtime-first dispatch) and run in scenario ID order |
| `--lpt-history-runs <n>` | Number of past runs to read for LPT ordering (default 5) |
| `--runner <runner>` / `--fleet <fleet>` | Dispatch to a remote machine or a fleet of machines over SSH (see [remote_runners.md](../in_action/remote_runners.md)) |
| `--platform <ios\|android>` | Target platform without `--profile` (default `ios`) |
| `--app-id <bundleID>` | Default app for scenarios with no `@TestClass(app:)`, only needed without `--profile`. Unrelated to `--set app=...` (the run profile's `app` key names an app *profile*, not a bundle ID) |
| `--port <n>` / `--serial <s>` | Bridge port (iOS) / device serial (Android) without `--profile` |

Run `fleetest run --help` for the full, current list.

## `run-file`

`fleetest run-file <path.swift>...` runs one or more `.swift` files that are **not** registered
in `Package.swift` (profiles, reports and self-healing are borrowed from an existing project via
`--project`). Useful for a throwaway scenario you do not want to add to the project yet. Accepts
`--project`, `--profile`, `--scenario`, `--set` (e.g. `--set heal=true`), `--report-dir`,
`--port`, `--app-id`, and `--platform`/`--serial`.

## Exit code and failure semantics

`fleetest run` exits `0` when everything passed, `1` if anything failed. Inside a scenario, a
failing command aborts the rest of that scenario (all remaining scenes and steps are skipped) —
`tearDown()` still runs. See [testcode_structure.md](../testclass/testcode_structure.md) for the
full failure model.

## Android

Point the same command at an emulator/physical device with `--platform android`, or list an
emulator device `name` in the run profile. No separate setup step is required — the on-device
bridge (`AndroidRunner`) installs and starts itself on first use.

```bash
fleetest run --platform android
```

## Device and bridge management

| Command | Description |
|---|---|
| `fleetest devices up` / `devices down` | Start/stop every device in the machine profile (or only a run profile's devices with `--profile`) |
| `fleetest bridge up` / `bridge down` / `bridge status` | Manage the resident bridge (iOS: XCUITest runner / Android: on-device server) |

### Link
- [index](../index.md)
