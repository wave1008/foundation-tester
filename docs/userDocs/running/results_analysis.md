# Results Analysis

Every `ftester run` (CLI or `ftester api run`) appends its results to
`TestProjects/<name>/results/`. This page covers the `ftester results` commands and how to read
a failure; the full JSON schema is the single source of truth at
[../../results-json.md](../../results-json.md).

## Layout

```
results/runs/<YYYY-MM>/<runID>/
  run.json                     ... this run as a whole
  scenarios/<scenarioID>.json  ... one scenario execution
  scenarios/<scenarioID>~2.json ... a re-run within the same run (numbered)
  host-metrics.ndjson          ... host load (cpu/gpu/mem) during the run
```

`results/` is an append-only, git-friendly layout: `runID` embeds the machine name and a random
suffix, so results from different machines/branches merge without conflicts.

## `ftester results` commands

| Command | Description |
|---|---|
| `ftester results list [--since <period>] [--limit <n>]` | List runs, newest first |
| `ftester results summary [--scenario <id>]` | Aggregate run count, pass rate and duration per scenario (lowest pass rate first) |
| `ftester results flaky [--min-runs <n>]` | Scenarios that both pass and fail, most flaky first |
| `ftester results trend --scenario <id>` | One scenario's run history in chronological order |
| `ftester results devices` | Run count and pass rate per worker (device) and per platform |
| `ftester results slow [--limit <n>]` | Scenarios by average duration, slowest first |
| `ftester results insights` | Ten checks over the run history — see [What `insights` detects](#what-insights-detects) |

All of them accept `--project`, `--since <period>` (a relative value like `30d`/`12h`, or
`YYYY-MM-DD`; default `90d`), and `--json` for single-line JSON output. Run
`ftester results <subcommand> --help` for the exact flags.

## What `insights` detects

`insights` reads the same recorded facts and reports patterns that only become visible across
several runs. Ten checks, each emitted as one row with a severity:

| kind | severity | Fires when |
|---|---|---|
| `newFailure` | critical | A scenario failed after a run of consecutive passes (possible regression) |
| `consecutiveFailures` | critical | A scenario has failed several runs in a row |
| `infraFailures` | warn | Repeated failures whose *signature* is not an assertion — see the note below |
| `selectorDecay` | warn | Reliance on self-healing/fallback is growing for a scenario |
| `healReliance` | warn | One selector has passed only via self-heal/cache for several runs — apply the suggestion |
| `unsettledSteps` | warn | Steps went ahead while the screen was still moving (a leading indicator of flakiness) |
| `deviceBias` | warn | Failures cluster on one worker/device rather than spreading evenly |
| `durationRegression` | warn | A scenario's duration grew against its own earlier history |
| `unfinishedRuns` | info | Runs ended incomplete (possible crash or force-quit) |
| `retiredScenarios` | info | Scenarios still have results but are no longer being run — excluded from the checks above |

> **On `infraFailures` and "cause".** This row does *not* claim to know what the environment was
> doing. It counts failures by their recorded signature — the run timed out, or it ended with
> `errorLogs` without reaching a single step — and contrasts that count with assertion failures.
> A scenario whose failures are mostly of that shape is worth looking at for a different reason
> than one failing an assertion; that is all the row asserts. Deciding whether a slow app or a
> busy machine was responsible is still yours to make, from evidence outside the tool.

## Reading a failed run

The tool records only observable facts — it does not guess whether a failure was "environmental"
(a slow app vs. a busy machine are indistinguishable from the outside).

| You want to know | Look at |
|---|---|
| Which phase failed | `failedSteps[].section` = `condition` / `action` / `expectation` / `setUp` / `tearDown` |
| Which command failed | `failedSteps[].command` |
| Which failure path | `failedSteps[].failureKind` (see below) |
| What was happening at that step | `failedSteps[].notes` (e.g. `interruption-dismissed`) |
| Whether the scenario never even reached a step | `failedSteps` is empty — check `errorLogs` / `skipKind` |
| Whether devices dropped out during the run | `run.json`'s `workerAnomalies` |

`failureKind` values: `selector-syntax` (caught before touching a device), `not-found` (locator
never resolved, even after scroll search), `assertion` (value/state mismatch), `driver-unreachable`
(bridge unreachable), `driver-error` (bridge returned an error), `timeout`, `app-not-installed`,
`system-ui-covered` (an OS system UI, such as a permission alert, was covering the app while
`iosAlertHandler` was registered). A missing `failureKind` means the tool could not tell —
it is left out rather than guessed.

```bash
# Count failed scenarios by phase x failureKind x command
jq -r 'select(.passed==false) | .failedSteps[0]
       | "\(.section // "-")\t\(.failureKind // "-")\t\(.command // "-")\t\(.description)"' \
  results/runs/2026-08/*/scenarios/*.json | sort | uniq -c
```

## In VS Code

The command palette's **"ftester: Open Results Dashboard"** opens a panel showing recent runs,
per-scenario pass rate/duration, flaky scenarios, per-device/worker aggregates, a daily trend and
insights — backed by the same `ftester results` data. See the "結果ダッシュボード" section of
[vscode-ftester/README.md](../../../vscode-ftester/README.md) (Japanese).

## CI

`ftester run --junit <path>` writes a JUnit XML report alongside the JSON results, for CI test
reporting. See [ci.md](../in_action/ci.md).

### Link
- [index](../index.md)
