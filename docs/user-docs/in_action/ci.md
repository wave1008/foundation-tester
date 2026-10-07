# Running on CI

[in Japanese(日本語)](ci_ja.md)

Scenarios execute deterministically with no LLM involved, so they fit CI: exit code and JUnit XML
are both machine-readable. This page summarizes the essentials for running a test project in
CI.

## Prerequisites

- **Self-hosted Mac only** (a Jenkins agent, an AWS EC2 Mac instance, etc.). iOS Simulators and
  Android Emulators require macOS, so GitHub-hosted runners (`macos-*`) are not supported — those
  run inside a macOS VM, which cannot use Apple Intelligence, and this path is not verified there.
- **Run as a logged-in GUI session user** — the general rule for driving Simulators. A headless
  `LaunchDaemon` or a bare `ssh` session makes Simulators unstable.
- **Apple Intelligence is not required.** Without it (a `⚠️` line is printed at startup), deterministic execution —
  tapping, asserting, and self-healing (locator fingerprint matching, which does not use FM) — runs unaffected.
  Two things change: **`screenLooksLike` passes without being checked**, and **text visual verification judges by OCR
  alone** ([Text visual verification](../reference/testclass/text_visual_check.md)). If you
  need visual checks enforced, see "Using Apple Intelligence in CI" below.
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
  (element list, screenshot, self-healing suggestions). Archive it as a build artifact so the
  JUnit `report:` line can be followed back to it.

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

- Device provisioning (Simulator boot, bridge) is handled automatically by a `--profile` run.
  Consecutive jobs reuse an already-running bridge; only the first run pays the cold-start cost.
- A run does not stop the bridge. A bridge exits on its own after a period without requests
  (`FT_BRIDGE_TTL`, 2 hours by default), and the working files of an exited bridge are deleted when
  the next job starts. An iOS bridge's working files **keep growing while it runs** (roughly
  120–240 MB per hour per bridge while it is being driven). If your jobs pause for 2 hours or more
  (overnight, for example), no cleanup is needed. **If jobs run around the clock without such a gap**,
  run `fleetest devices down` periodically.
- To clean up between jobs, add `fleetest devices down` (stops every bridge and shuts down every
  Simulator/Emulator) at the end of the job. While another test run on the same Mac is using a
  device, it stops nothing and exits with code 1 so that it does not kill that run. If jobs can
  overlap on the same Mac, schedule the cleanup for a time when no other job is running.
- **One run at a time per Mac.** A second `fleetest run` on the same agent does not start — it
  stops with `another fleetest run is already running on this Mac`. Either keep jobs that share an
  agent from overlapping, or add `--wait-lock <seconds>` so the second one queues instead of
  failing (see [Parallel execution](../reference/running/parallel_execution.md)).

## Using Apple Intelligence in CI (optional)

Apple Intelligence works only when the runner is a physical Mac (bare metal). It cannot be enabled
inside a macOS VM (Tart, Anka and the like), so plan on it being unavailable there.

- Physical Mac (a standing Jenkins machine, for example): works.
- AWS EC2 Mac (bare metal): should work in principle, but it is unverified.
- macOS VM: does not work. `screenLooksLike` passes without being checked, and text visual verification judges by OCR alone.

To enable it on bare metal:

- Apple silicon with macOS 26 or later. `screenLooksLike` and text visual verification (image input) need macOS 27 or later.
- Enable it once in the GUI (System Settings → Apple Intelligence & Siri; on a machine without a display, through Screen Sharing.
  A model download runs). An EC2 Mac loses the setting when recreated from a plain AMI, so bake a custom AMI after enabling it,
  or include the enabling in your provisioning.
- Run `fleetest doctor --fm-only` at the start of the job and check its exit code. The setting can say "available" while
  calls still fail, so doctor really runs an inference.
- FM is a resource shared by the whole Mac, and only one call runs at a time. A suite that uses `screenLooksLike` heavily takes longer.
- Self-healing (locator fingerprint matching) does not use FM, so it runs in CI regardless of Apple Intelligence.

## Flaky scenarios (no retry mechanism, by design)

There is no built-in per-scenario retry in CI: automatic retries hide flakiness and let it rot.
Instead:

- **Detection**: `fleetest results flaky` lists scenarios with mixed pass/fail history, ranked by
  instability (`fleetest results insights` also flags regressions, failures with a non-assertion
  signature, and stale selectors).
- **Local reproduction**: `fleetest run --failed` re-runs only the scenarios that failed last time.
- Infrastructure-caused failures (e.g. a frozen device) are automatically requeued *within* a run
  — the failed result is discarded and the scenario reruns on another device, so only the final
  result reaches JUnit. This is a recovery mechanism, not a retry policy.

### Link
- [index](../index.md)
