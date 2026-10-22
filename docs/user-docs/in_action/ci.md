# Running on CI

[in Japanese(日本語)](ci_ja.md)

Scenarios execute deterministically with no LLM involved, so they fit CI: exit code and JUnit XML
are both machine-readable. This page takes you step by step until a test project runs in CI.
It uses Jenkins as the example, but steps 1 to 3 are the same on other CI systems.

## 1. Prepare the CI machine

- **Self-hosted Mac only** (a Jenkins agent, an AWS EC2 Mac instance, etc.). iOS Simulators and
  Android Emulators require macOS, so GitHub-hosted runners (`macos-*`) are not supported — those
  run inside a macOS VM, which cannot use Apple Intelligence, and this path is not verified there.
- **Run as a logged-in GUI session user** — the general rule for driving Simulators. A headless
  `LaunchDaemon` or a bare `ssh` session makes Simulators unstable.
- Xcode (and the Android SDK, if running Android scenarios) already installed on the runner.
- **If the project has `scripts/compose.yaml`** ([service declarations](../reference/writing/services.md)):
  the CI machine needs Apple Container or Docker. Build your own images on the CI machine or load them with
  `fleetest services load <tar>` (nothing is pulled for them). Registry images are pulled on first use, so outbound network
  access is required. A run does not start if the Docker API is exposed over TCP (2375 / 2376).
- **Apple Intelligence is not required.** Without it, deterministic execution and self-healing run unaffected
  (what changes is under "Things to know" at the end).

What success looks like: in a terminal of the same user as the CI job (a logged-in GUI session), `xcodebuild -version` prints a version.

## 2. Install fleetest

The extension and MCP aren't needed in CI. The command is idempotent — a second run is mostly a no-op.

```bash
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor
```

What success looks like: each step prints one line, and on a second run most of them are skipped.

## 3. Put the run command in the job

```bash
# Run: --quiet suppresses per-step lines, --junit writes JUnit XML
fleetest run --profile ios-run --quiet --junit reports/junit.xml
```

- **Exit code**: `0` = every scenario passed, `1` = at least one failure (JUnit is still written
  on failure). When the run fails before any scenario starts, JUnit is written too: a failure while preparing
  devices lists each scenario as a failure, and a failure to build the scenarios shows up as a single failed
  testcase named `build`. Mistakes in the command line itself (an unknown scenario or folder name) write no JUnit.
- Device provisioning (Simulator boot, bridge) is handled automatically by a `--profile` run.
  Consecutive jobs reuse an already-running bridge; only the first run pays the cold-start cost.
- **Investigating a failure**: `TestProjects/<name>/reports/` holds a Markdown report per failure
  (element list, screenshot, self-healing suggestions). Archive it as a build artifact so the
  JUnit `report:` line can be followed back to it.

What success looks like: when every scenario passes, the command ends with exit code `0` and `reports/junit.xml` exists.
If even one fails, the exit code is `1`, but `reports/junit.xml` has still been written.

## 4. Have CI read the JUnit

`<testsuite>` per scenario class, `<testcase>` per scenario. A failure carries the
first failing step's summary, every failing step with its source location, the Markdown report
path, and the worker it ran on. A scenario is `<skipped>` only when *every* step in it is
inconclusive (a `verify` with zero assertions) — mixed with normal steps, it is folded into a
passing `<testcase>` instead (visible in the run log and the Markdown report's ❓ marker and fix
suggestion).

### Prompt for the AI

The job definition (a Jenkinsfile, …) can be written by the AI.

```text
Create a Jenkinsfile in this repository. Stages: "install fleetest idempotently with install.sh", then "fleetest run --profile ios-run --quiet --junit reports/junit.xml". In post, collect the JUnit, and on failure archive reports/junit.xml and TestProjects/*/reports/ as artifacts.
```

<details>
<summary><b>If you write it by hand (click to show details)</b></summary>

A Jenkins example:

```groovy
pipeline {
  agent { label 'mac' }   // an agent that runs as a logged-in GUI session user
  stages {
    stage('Install / update') {
      steps { sh 'bash ../foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor' }
    }
    stage('Run scenarios') {
      steps { sh '../foundation-tester/.build/debug/fleetest run --profile ios-run --quiet --junit reports/junit.xml' }
    }
  }
  post {
    always  { junit 'reports/junit.xml' }
    failure { archiveArtifacts artifacts: 'reports/junit.xml, TestProjects/*/reports/**', allowEmptyArchive: true }
  }
}
```

</details>
<br>

What success looks like: the job's result page lists test results per scenario class. For a failed job,
`reports/junit.xml` and the reports are kept as build artifacts, and the JUnit `report:` line leads to the report.

## 5. Make it periodic, and clean up between jobs

Have the job start periodically (in Jenkins, `triggers { cron('H 2 * * *') }`; for splitting what runs every time from what runs at night, see
[Running smoke and regression separately](../tutorial/smoke_and_regression.md)). When jobs run back to back, settle these three points.

- **One run at a time per Mac.** A second `fleetest run` on the same agent does not start — it
  stops with `another fleetest run is already running on this Mac`. Either keep jobs that share an
  agent from overlapping, or add `--wait-lock <seconds>` so the second one queues instead of
  failing (see [Parallel execution](../reference/running/parallel_execution.md)).
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
  Without a profile, `devices down` sends the same sweep to every machine in the remote registry too, so a CI
  machine that has runners registered would also stop Simulators on those machines. Pass `--profile`, or keep no registry on it.

### Prompt for the AI

```text
Add a nightly 2 a.m. schedule to the Jenkinsfile. Give fleetest run --wait-lock 1800, and run fleetest devices down --profile ios-run at the end of the job.
```

What success looks like: overlapping jobs run one after another if they carry `--wait-lock`, and stop with the message above if they do not.

## Things to know

### Using Apple Intelligence in CI (optional)

Without Apple Intelligence in CI, two things change: **`screenLooksLike` passes without being checked**, and
**text visibility check judges by OCR alone** ([Text visibility check](../reference/testclass/text_visibility_check.md)).
A `⚠️` line is printed at startup. If you need visual checks enforced, read on.

Apple Intelligence works only when the runner is a physical Mac (bare metal). It cannot be enabled
inside a macOS VM (Tart, Anka and the like), so plan on it being unavailable there.

- Physical Mac (a standing Jenkins machine, for example): works.
- AWS EC2 Mac (bare metal): should work in principle, but it is unverified.
- macOS VM: does not work. `screenLooksLike` passes without being checked, and text visibility check judges by OCR alone.

To enable it on bare metal:

- Apple silicon with macOS 27 or later (`screenLooksLike` and text visibility check pass images to FM, so they are not available on macOS 26).
- Enable it once in the GUI (turn Siri on in System Settings → Siri (Siri uses Apple Intelligence); on a machine without a display, through Screen Sharing.
  A model download runs). An EC2 Mac loses the setting when recreated from a plain AMI, so bake a custom AMI after enabling it,
  or include the enabling in your provisioning.
- Run `fleetest doctor --fm-only` at the start of the job and check its exit code. The setting can say "available" while
  calls still fail, so doctor really runs an inference.
- FM is a resource shared by the whole Mac, and only one call runs at a time. A suite that uses `screenLooksLike` heavily takes longer.
- Self-healing (locator fingerprint matching) does not use FM, so it runs in CI regardless of Apple Intelligence.
- When self-healing fires, the fixed selectors are written back to the scenario sources in the checkout (the tool does not commit). If you don't want a dirty checkout, pass `--set heal=false`, or just ignore it.

### Flaky scenarios (no retry mechanism, by design)

There is no built-in per-scenario retry in CI: automatic retries hide flakiness and let it rot.
Instead:

- **Detection**: `fleetest results flaky` lists scenarios with mixed pass/fail history, ranked by
  instability (`fleetest results insights` also flags regressions, failures with a non-assertion
  signature, and stale selectors).
- **Local reproduction**: `fleetest run --failed` re-runs only the scenarios that failed last time.
- Infrastructure-caused failures (e.g. a frozen device) are automatically requeued *within* a run
  — the failed result is discarded and the scenario reruns, so only the final
  result reaches JUnit. This is a recovery mechanism, not a retry policy.
- **A requeue runs the scenario again from the start** (on the same device or on another one).
  When a device's display is confirmed to have frozen, the scenario that **passed** just before on that device is also
  discarded and run again (it was judged on a frozen screen). A scenario with an operation that cannot be undone, such as
  sending, purchasing or registering, can therefore run twice within one run. There is no setting to turn requeuing off.
  **Write scenarios on the assumption that they may be re-run from the start**
  ([Writing Robust Scenarios](../reference/writing/writing_robust_scenarios.md)).
  Point operations that cannot be undone at an environment where running them twice does no harm (test payments, a
  staging server).

What to do once you have found one is in "What to do once you find one" in [Reading Results and Investigating Failures](../tutorial/investigating_failures.md).

### Link
- [index](../index.md)
