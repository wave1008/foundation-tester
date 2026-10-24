# CLI reference (fleetest subcommands)

[in Japanese(日本語)](cli_ja.md)

A list of the `fleetest` subcommands, grouped by purpose. `--help` shows the full arguments of each command.
This page is a map for finding which command exists and where to read more.

## How to call it

In this documentation, `fleetest` stands for `../foundation-tester/.build/debug/fleetest` in the default layout where
foundation-tester is cloned next to your work folder (see the [Quick Start](../../quick-start.md)).
If you work inside the foundation-tester clone, `swift run fleetest` is equivalent.

```bash
../foundation-tester/.build/debug/fleetest --help                  # list of subcommands
../foundation-tester/.build/debug/fleetest help run                # detailed help for a subcommand
../foundation-tester/.build/debug/fleetest help bridge up          # detailed help for a child command
../foundation-tester/.build/debug/fleetest bridge --help           # list of child commands
```

`fleetest help <subcommand>` shows every option of that subcommand with its default.
`bridge`, `project`, `profile`, `devices`, `results`, `remote`, `services`, `hooks`, `monitor`, `vision` and `api` have
child commands. `fleetest --version` shows the version.

## Preparation and diagnosis

| Command | Description | Main options | Details |
|---|---|---|---|
| `init` | Create your package (a `Package.swift` that depends on fleetest via SPM, plus a first test project) | `--no-project`, `--name` | [Quick Start](../../quick-start.md) |
| `doctor` | Preflight checks for Foundation Models, Xcode and simulators. It also stops bridges that are certainly stale | `--fm-only`, `--roots-only`, `--bundle <path>` | [Troubleshooting](../../in_action/troubleshooting.md) |

`doctor --bundle <path>` writes a zip of diagnostic logs to attach when reporting a problem (nothing is sent anywhere).

## Projects and profiles

| Command | Description | Main options | Details |
|---|---|---|---|
| `project create <name>` | Scaffold a test project and register it in `Package.swift` | — | [Creating a Test Project](../project/creating_project.md) |
| `project list` | List test projects and whether they are registered in `Package.swift` | — | Same as above |
| `project sync` | Regenerate the marker section of `Package.swift` from a scan of `TestProjects/` (to resync after a manual copy or a git pull) | — | Same as above |
| `project lint-selectors` | Check for drift between the `#id` selectors in scenarios and the contract (`ui-contract.md`) (only `#id`) | `--project`, `--contract` | Same as above |
| `project copy <source> <new-name>` | Duplicate a test project under a new name (excludes reports / results / `.fleetest` state) | — | Same as above |
| `project rename <old-name> <new-name>` | Rename a test project and update `Package.swift` | — | Same as above |
| `project delete <name>` | Move a test project to the Trash and remove it from `Package.swift` | `--yes` (required; without it nothing is deleted) | Same as above |
| `profile setup` | Create app and run profiles consistently (idempotent) | `--platform`, `--app-id`, `--auto-device`, `--count`, `--app-path` | [Profiles](../project/profiles.md) |
| `profile list` | List run profiles and their component profiles, and show how they resolve on this machine | `--project` | Same as above |

The settings of a run profile are in [Run profile settings](../project/run_profile.md).

## Running and results

| Command | Description | Main options | Details |
|---|---|---|---|
| `run` | Run Swift DSL scenarios | `--profile`, `--scenario`, `--folder`, `--failed`, `--dry-run`, `--set`, `--junit`, `--runner`, `--fleet` | [Running scenarios](../running/running_scenarios.md) |
| `run-file <file>` | Run an unregistered `.swift` scenario as-is (profiles are borrowed from an existing project) | `--project`, `--profile`, `--scenario` | [Running scenarios](../running/running_scenarios.md) |
| `draft-scenario` | Generate a scenario draft from a test base (`docs/testbases/*.md`) | `--testbase`, `--name`, `--no-fm`, `--dry-run` | [Test bases and scenario drafts](../running/testbases.md) |
| `results list` | List runs, newest first | `--since`, `--limit`, `--json` | [Analysing results](../running/results_analysis.md) |
| `results summary` | Aggregate run count, pass rate and duration per scenario (lowest pass rate first) | `--scenario`, `--since`, `--json` | Same as above |
| `results flaky` | List scenarios that both pass and fail, most flaky first | `--min-runs`, `--since` | Same as above |
| `results trend` | Show the run history of a single scenario in chronological order | `--scenario` (required), `--since` | Same as above |
| `results devices` | Aggregate run count and pass rate per worker (device) and per platform | `--since`, `--json` | Same as above |
| `results slow` | List scenarios by average duration, slowest first | `--limit`, `--since` | Same as above |
| `results response` | Aggregate response times (time to first frame and time until ready) of response-measurement runs per step, with the change from the previous run on the same host and device | `--since`, `--json` | [Response measurement](../running/response_measurement.md) |
| `results insights` | Detect things worth attention: regressions, consecutive failures, failures with a non-assertion signature, and stale selectors | `--since`, `--json` | [Analysing results](../running/results_analysis.md) |
| `results log <run-id>` | Print a run's per-scenario execution log (`events/*.ndjson`). The run ID can also be `latest` | `--scenario`, `--raw` | Same as above |
| `clean` | Delete old recordings, event logs, reports, logs, simulator attachments and xcresult bundles. Any category above 90% of its limit is swept back down to 90% | `--dry-run`, `--recordings`, `--event-logs`, `--reports`, `--logs` | [Maintenance for long-term use](../../in_action/maintenance.md) |

## Devices and bridges

| Command | Description | Main options | Details |
|---|---|---|---|
| `devices up` | Start the devices in the run profiles (at most two at a time; already-running devices are skipped) | `--profile`, `--no-bridge`, `--device-machine` | [Running scenarios](../running/running_scenarios.md) |
| `devices down` | Stop every bridge and shut down simulators and emulators (physical devices are never shut down, only their bridges are stopped). With `--profile`, only that profile's devices | `--profile`, `--device-machine`, `--force` | [Parallel Execution](../running/parallel_execution.md) |
| `bridge up` | Start the bridge and keep it resident (iOS: a simulator runner / Android: an on-device server) | `--device`, `--port`, `--physical`, `--platform` | [Parallel Execution](../running/parallel_execution.md) |
| `bridge down` | Stop the bridge | `--port`, `--all`, `--platform`, `--force` | [Parallel Execution](../running/parallel_execution.md), [Adding physical devices](../../fleet/adding_physical_devices.md) |
| `bridge status` | Show the bridge status | `--platform`, `--port`, `--serial` | [Troubleshooting](../../in_action/troubleshooting.md) |
| `install <package-path>` | Install an app from a package file (iOS: `.app` bundle / Android: `.apk` or `.apks`) | `--platform`, `--port`, `--serial` | "Operating a device by hand" below |
| `launch <bundle-id>` | Launch the app under test | Same as above | Same as above |
| `terminate` | Terminate the app under test | Same as above | Same as above |
| `monitor pause` | Stop this Mac's device monitor (observation and streaming) | `--for <minutes>` | [Response measurement](../running/response_measurement.md) |
| `monitor resume` | Release the hold (idempotent) | — | Same as above |
| `monitor status` | Show whether a hold is active | — | Same as above |

`monitor pause` stops the monitor's polling and makes the VSCode extension close its streaming helpers, for example before a
performance-measuring run (`run --performance`). It does not kill any process (killed processes just get restarted by the extension).
An expired `--for` releases the hold by itself.

## Operating a device by hand

These are the CLI versions of the same operations as the MCP `ft_*` tools ([MCP Server](./mcp_server.md)). They send screen reading
and basic operations directly to a device whose bridge is running, which is useful for looking at a screen before writing a scenario
or for isolating a problem. The target is given by the common options `--platform` (ios / android; default ios), `--port` (the iOS
bridge port; default 8123) and `--serial` (the Android device; optional when only one is connected).

| Command | Description | Main options |
|---|---|---|
| `snapshot` | Print the accessibility tree of the current screen (compressed) | `--json` (raw JSON) |
| `tap` | Tap an element or a coordinate | `--ref` (reference number from snapshot), `--x`, `--y` |
| `type <text>` | Type text (with `--ref`, taps the element first) | `--ref` |
| `swipe <direction>` | Swipe (direction: up / down / left / right) | — |
| `press` | Long-press an element | `--ref` (required), `--hold-seconds` |
| `screenshot` | Save a screenshot | `-o` / `--output` (default `screenshot.png`) |

`install`, `launch` and `terminate` take the same target options. `--ref` is the reference number shown by the latest `snapshot`.

## Services and hooks

| Command | Description | Main options | Details |
|---|---|---|---|
| `services up` | Start the services declared in `scripts/compose.yaml` and keep them running until `services down` (for exploration, live control and scenario writing; a run takes them over and starts them again) | `--profile`, `--physical`, `--serial` | [Services the app depends on](../writing/services.md) |
| `services down` | Stop the services started by `services up` (services held by a run are left to that run) | `--profile` | Same as above |
| `services status` | Show the leases, the lock and the runtime resources of this workspace's services | `--profile` | Same as above |
| `services pull` | Pull the images `compose.yaml` declares ahead of a run (and build the relay image on first use) | `--refresh` | Same as above |
| `services load` | Load images from a tar archive into this Mac's container runtime, for machines without network access to the registry | — | Same as above |
| `services reset` | Remove this workspace's service containers, networks and volumes, and its leases and lock | — | Same as above |
| `hooks reap` | Run the teardown scripts left behind by runs that died before they could clean up | `--quiet` | Same as above |

## Fleet

| Command | Description | Main options | Details |
|---|---|---|---|
| `remote setup <runner>` | Provision a remote Mac to receive `--runner` dispatches (idempotent) | `--remote-dir`, `--skip-verify` | [Adding a Mac](../../fleet/adding_mac.md) |
| `remote machines` | Manage the machine registry (local alias to SSH destination). Child commands: `list` (default), `add`, `remove` | `add <machine> --host <destination>` | [Remote Runners](../../fleet/remote_runners.md) |
| `remote status` | Show reachability, login state, git revision, toolchain and free disk space of the remote runners | `--runner`, `--fm`, `--json` | Same as above |
| `remote align` | Fetch, checkout and build the local HEAD revision on a runner (the align step of `remote setup` alone) | `--remote-dir` | Same as above |
| `remote exec <runner> -- <args>` | Run `fleetest <args>` on a remote runner and relay its output and exit code | `--remote-dir` (before the `--`) | Same as above |
| `remote clean` | Stop orphaned bridges and simulators and delete results, reports and dispatch leftovers older than `--keep-days` on remote runners | `--runner`, `--keep-days` | Same as above |
| `remote unlock` | Release a dispatch lock that a dead dispatch left behind (never releases a lock whose run is still alive unless `--force`) | `--runner`, `--force` | Same as above |
| `remote teardown` | Delete the remote base directory of a runner (destructive) | `--remote-dir` | Same as above |

The `--runner` (send to one runner), `--fleet` (send across several machines with a fleet definition), `--split`, `--broadcast` and
`--wait-lock` options of `run` are described in [Remote Runners](../../fleet/remote_runners.md) and
[Parallel Execution](../running/parallel_execution.md).

## Images

| Command | Description | Main options | Details |
|---|---|---|---|
| `vision capture` | Crop an element from the live screen by its accessibility frame and save it as a sample image of an image classifier | `--classifier`, `--label`, `--selector` (all required), `--name` | [Image assertion](../commands/image_assertion.md) |
| `vision check` | Train the classifiers if needed and report the sample images each one cannot tell apart (warnings only; the exit code stays 0) | `--classifier`, `--project` | Same as above |

## For external tools (api)

`api` is the **machine-facing entry** used by external tools such as the VSCode extension and the MCP server (JSON or NDJSON on
standard output, diagnostics on standard error). It is not meant to be typed by hand. Only representative child commands are listed
here; `fleetest api --help` shows all of them.

| Child command | Description |
|---|---|
| `api list-scenarios` | Print the scenario list as JSON, including source locations (file and line) |
| `api steps` | Dry-run a scenario and print the equivalent of its step table as JSON |
| `api run` | Run scenarios and stream events as NDJSON |
| `api monitor` | Poll the devices in the run profiles at a fixed interval and stream their state and screenshots as NDJSON |
| `api list-devices` | Evaluate every device on this machine and its current state once, and print it as JSON |
| `api validate-profile` | Validate the profile JSON (apps / runs) |
| `api results` | Aggregate the run-results database (the machine-facing side of `fleetest results`) |
| `api retention` | Read or update the retention policy |

For the extension see the [VS Code Extension](./vscode_extension.md), and for MCP see the [MCP Server](./mcp_server.md).

### Link
- [index](../../index.md)
