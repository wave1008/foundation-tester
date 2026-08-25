# Running in CI

Scenarios execute deterministically with no LLM involved, so they fit CI: exit code and JUnit XML
are both machine-readable. This page summarizes the essentials for running a receiver package in
CI; see [docs/ci.md](../../ci.md) for the full write-up.

## Prerequisites

- **Self-hosted Mac only** (a Jenkins agent, an AWS EC2 Mac instance, etc.). iOS simulators and
  Android emulators require macOS, so GitHub-hosted runners (`macos-*`) are not supported — those
  run inside a macOS VM, which cannot use Apple Intelligence, and this path is not verified there.
- **Run as a logged-in GUI session user** — the general rule for driving simulators. A headless
  `LaunchDaemon` or a bare `ssh` session makes simulators unstable.
- **Apple Intelligence is not required.** Without it, self-healing / `screenLooksLike` / false-
  positive checks are automatically skipped (a `⚠️` line is printed at startup) while deterministic
  execution — tapping, asserting — runs unaffected. A scenario that uses `screenLooksLike` or
  `requireVisible` passes without actually being checked in that case (the FM warning at the end
  of the run says so). See "Using Apple Intelligence in CI" in [docs/ci.md](../../ci.md) if you
  need visual checks enforced.
- Xcode (and the Android SDK, if running Android scenarios) already installed on the runner.

## Running and retrieving results

```bash
# Install/update (idempotent — a second run is mostly a no-op). The extension and MCP aren't needed in CI
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor

# Run: --quiet suppresses per-step lines, --junit writes JUnit XML
fleetest run --profile ios-xcuitest --quiet --junit reports/junit.xml
```

- **Exit code**: `0` = every scenario passed, `1` = at least one failure (JUnit is still written
  on failure).
- **JUnit XML**: `<testsuite>` per scenario class, `<testcase>` per scenario. A failure carries the
  first failing step's summary, every failing step with its source location, the Markdown report
  path, and the worker it ran on. A scenario is `<skipped>` only when *every* step in it is
  inconclusive (a `verify` with zero assertions) — mixed with normal steps, it is folded into a
  passing `<testcase>` instead (visible in the run log and the Markdown report's ❓ marker and fix
  suggestion).
- **Investigating a failure**: `TestProjects/<name>/reports/` holds a Markdown report per failure
  (element list, screenshot, FM triage). Archive it as a build artifact so the JUnit `report:` line
  can be followed back to it.

## Jenkins example

```groovy
pipeline {
  agent { label 'mac' }   // an agent that runs as a logged-in GUI session user
  stages {
    stage('Install / update') {
      steps { sh 'bash ../foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor' }
    }
    stage('Run scenarios') {
      steps { sh '../foundation-tester/.build/debug/fleetest run --profile ios-xcuitest --quiet --junit reports/junit.xml' }
    }
  }
  post {
    always  { junit 'reports/junit.xml' }
    failure { archiveArtifacts artifacts: 'reports/junit.xml, TestProjects/*/reports/**', allowEmptyArchive: true }
  }
}
```

- Device provisioning (simulator boot, bridge) is handled automatically by a `--profile` run.
  Consecutive jobs reuse an already-running bridge; only the first run pays the cold-start cost.
- To clean up between jobs, add `fleetest devices down` (stops every bridge and shuts down every
  simulator/emulator) at the end of the job.

## Flaky scenarios (no retry mechanism, by design)

There is no built-in per-scenario retry in CI: automatic retries hide flakiness and let it rot.
Instead:

- **Detection**: `fleetest results flaky` lists scenarios with mixed pass/fail history, ranked by
  instability (`fleetest results insights` also flags regressions, infrastructure-caused failures,
  and stale selectors).
- **Local reproduction**: `fleetest run --failed` re-runs only the scenarios that failed last time.
- Infrastructure-caused failures (e.g. a frozen device) are automatically requeued *within* a run
  — the failed result is discarded and the scenario reruns on another device, so only the final
  result reaches JUnit. This is a recovery mechanism, not a retry policy.

### Link
- [index](../index.md)
