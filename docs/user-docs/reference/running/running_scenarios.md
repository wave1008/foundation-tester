# Running scenarios (fleetest run)

[in Japanese(日本語)](running_scenarios_ja.md)

`fleetest run` executes Swift DSL scenarios deterministically — ordinary playback and self-healing
(locator fingerprint matching) never call FM. This page covers the CLI options; see
[dry_run.md](./dry_run.md) for `--dry-run` and [self_healing.md](./self_healing.md) for
enabling self-healing with `--set`.

## Invoking the CLI

In the rest of this documentation, `fleetest` is `../foundation-tester/.build/debug/fleetest` in the
default layout, where foundation-tester is cloned next to your work folder. Inside the
foundation-tester clone itself, `swift run fleetest` does the same.

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

## Common options

| Option | Description |
|---|---|
| `--project <project>` | Test project name (see [creating_project.md](../project/creating_project.md) for the resolution order when omitted) |
| `--profile <profile>` | Run profile name (`profiles/runs/<name>.json`). Includes device provisioning and auto-install. **Cannot be combined with `--platform`/`--port`/`--serial`/`--app-id`** (the profile supplies all of those) — combining them is an error, not a silent override |
| `--scenario <id>` | Scenario ID: a class name alone runs every scenario in it, or `Class.method` for one. Repeatable; defaults to all. `@Deleted`/`@Draft` scenarios only run on an exact match |
| `--folder <folder>` | Scenario folders to run (subfolders directly under `scenarios/`). Repeatable; combinable with `--scenario`/`--failed` |
| `--failed` | Run only the scenarios that failed last time. Results are recorded per `(project, profile)` in `.fleetest/last-results/` on every run — a scenario that failed under one run profile is not hidden by a green run of a different profile, and a profile-less run has its own bucket. `--failed` looks at the profile you pass to this same invocation (or the profile-less bucket if you omit `--profile`). "Failed" means the scenario's last attempt did not pass — this includes scenarios that could not start (no worker/device available, the run was interrupted, or device supply failed), but not scenarios skipped as not applicable (declared for another platform) |
| `--set <key>=<value>` | Override a run profile key for this run only (repeatable; works with or without `--profile`; e.g. `--set heal=true`, `--set defaultTimeout=8`). The rules — available keys, value types, keys that require `--profile` — are in [Run profile keys](../project/run_profile.md) |
| `--dry-run` | Validate steps without touching a device (see [dry_run.md](./dry_run.md)) |
| `--report-dir <dir>` | Directory to write reports to (default: `TestProjects/<name>/reports`). Cannot be combined with `--set reportDir=...` |
| `--port <port>` | iOS bridge port (without `--profile`). Give it more than once for a manual parallel run (`--port 8123 --port 8124`; see [parallel_execution.md](./parallel_execution.md)) |
| `--skip-build` | Skip the `swift build` before running |
| `--quiet` | Print only the summary (for CI and agents) |
| `--junit <path>` | Write a JUnit XML report to this path |
| `--broadcast` | Run the selected scenarios once on **every** device of the run profile, instead of sharing them out (e.g. a warm-up). Requires `--profile`; results are told apart by their `worker` field (see [results_analysis.md](./results_analysis.md)) |
| `--no-lpt` | Disable LPT ordering (longest-past-runtime-first dispatch) and run in scenario ID order |
| `--lpt-history-runs <n>` | Number of past runs to read for LPT ordering (default 5) |
| `--runner <runner>` / `--fleet <fleet>` | Dispatch to a remote machine or a fleet of machines over SSH (see [Remote Runners](../../fleet/remote_runners.md)) |
| `--platform <ios\|android>` | Target platform without `--profile` (default `ios`) |
| `--app-id <bundleID>` | Default app for scenarios with no `@TestClass(app:)`, only needed without `--profile`. Unrelated to `--set app=...` (the run profile's `app` key names an app *profile*, not a bundle ID) |
| `--serial <s>` | Android device serial (without `--profile`) |

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
`afterEach()` still runs. See [testcode_structure.md](../testclass/testcode_structure.md) for the
full failure model.

## Android

Point the same command at an Emulator/physical device with `--platform android`, or list an
Emulator device `name` in the run profile. No separate setup step is required — the on-device
bridge (`AndroidRunner`) installs and starts itself on first use.

```bash
fleetest run --platform android
```

## Device and bridge management

| Command | Description |
|---|---|
| `fleetest devices up` / `devices down` | Start/stop the union of every run profile's devices (or only one run profile's devices with `--profile`) |
| `fleetest bridge up` / `bridge down` / `bridge status` | Manage the resident bridge (iOS: XCUITest runner / Android: on-device server) |

### Link
- [index](../../index.md)
