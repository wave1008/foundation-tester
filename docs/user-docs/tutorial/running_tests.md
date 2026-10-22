# Running tests

[in Japanese(日本語)](running_tests_ja.md)

Run the tests you created. AI is not used for the run itself (scenarios are replayed deterministically as code).

## 1. Verify without a device (dry-run)

### Prompt for the AI

```text
Dry-run all scenarios in the fleetest test project myshop and list any warnings.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --dry-run
```

In VSCode, select a scenario in the Test Explorer and use "Run (dry-run)".

</details>

## 2. Run

### Prompt for the AI

```text
Run all scenarios in the fleetest test project myshop on iOS and report the results when it's done.
```

To run only one test or a subset, specify them by test name or screen.

```text
Run only the login test in the fleetest test project myshop on Android.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
# Everything
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run

# Per class (file) or per single test
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario LoginTest
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario LoginTest.S0010
```

In VSCode, select a scenario in the Test Explorer and click "Run" (choose the run profile with
`fleetest: Select Run Profile` in the Command Palette; if there is only one, it is selected automatically).

</details>
<br>

## 3. Run faster on multiple devices

### Prompt for the AI

```text
Run the scenarios in the fleetest test project myshop in parallel, distributed across all devices of the run profile ios-run.
```

If the run profile contains multiple devices, scenarios are distributed automatically with no change to the scenarios. For how to add devices, see [Prepare the app and devices](preparing_app_and_devices.md).

<img src="../images/tutorial/en/parallel_run.png" width="640" alt="fleetest distributes six scenarios across three devices automatically">

When you want to run the same scenario once on every device (for example, to compare how it looks on each model), ask for that.

```text
Run the login test in the fleetest test project myshop once on every iOS device.
```

## 4. Re-run only the tests that failed

### Prompt for the AI

```text
In the fleetest test project myshop, re-run only the scenarios that failed on iOS last time.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --failed
```

</details>

## What happens on failure

### Prompt for the AI

```text
Find the scenarios in the fleetest test project myshop that contain irreversible operations such as submitting, purchasing or registering,
and check that they point at a test payment or a staging server.
```

- If even one place fails, the rest of that scenario is not run. Other scenarios continue.
- A failed operation is never retried automatically.
- However, when a device problem means the result cannot be trusted, a whole scenario can be rerun from the start. **An irreversible operation such as submitting, purchasing or registering can therefore happen twice in one run.** Point such scenarios at something where doing it twice is harmless (a test payment, a staging server) ([Run in CI](../in_action/ci.md), [Writing robust scenarios](../reference/writing/writing_robust_scenarios.md)).
- Minor changes such as only a screen ID having changed are absorbed by self-healing, and at the end of the run the fixed selector is written back to the scenario source automatically. Review the diff in git and commit it ([Keep tests up to date with app changes](keeping_up_with_app_changes.md)).

To investigate failures, see [Read results and investigate failures](investigating_failures.md).

## Run on another Mac or in CI

[Remote Runners](../fleet/remote_runners.md) · [Run in CI](../in_action/ci.md)

## More details

[Running scenarios (fleetest run)](../reference/running/running_scenarios.md) · [Dry-run](../reference/running/dry_run.md) · [Parallel execution](../reference/running/parallel_execution.md) · [Services the app depends on](../reference/writing/services.md)

Next: [Reading results and investigating failures](investigating_failures.md)

### Link
- [index](../index.md)
