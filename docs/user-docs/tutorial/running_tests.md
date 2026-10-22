# Running tests

[in Japanese(日本語)](running_tests_ja.md)

Run the tests you created. AI is not used for the run itself (scenarios are replayed deterministically as code).
This page runs the tests you made in the Quick Start and in "Creating tests" on iOS.

## 1. Verify without a device (dry-run)

### Prompt for the AI

```text
Dry-run all scenarios in the fleetest test project project1 and list any warnings.
```

No device is started, so it finishes in a few seconds.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project project1 --dry-run
```

In VSCode, select a scenario in the Test Explorer and use "Run (dry-run)".

</details>
<br>

What you'll see: with no warnings, you are told there are no problems.

## 2. Run (in parallel on two devices)

### Prompt for the AI

```text
Run all scenarios in the fleetest test project project1 on iOS (ios-run) and report the results when it's done.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
# Everything
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run

# Per class (file) or per single test
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --scenario <ClassName>
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --scenario <ClassName>.<methodName>
```

`<ClassName>` is the scenario's class name (it is inside the Swift file under `scenarios/`).

In VSCode, select a scenario in the Test Explorer and click "Run" (choose the run profile with
`fleetest: Select Run Profile` in the Command Palette; if there is only one, it is selected automatically).

</details>
<br>

What you'll see: `ios-run` has the two devices you set up in [Preparing devices](preparing_app_and_devices.md), so the scenarios are distributed
to both automatically and the two devices in the Device Monitor run different scenarios at the same time. A list of pass/fail appears when it finishes
(no change to the scenarios is needed).

<img src="../images/tutorial/en/parallel_run.png" width="640" alt="fleetest distributes six scenarios across two devices automatically">

More details: [Running scenarios (fleetest run)](../reference/running/running_scenarios.md) · [Dry-run](../reference/running/dry_run.md) · [Parallel execution](../reference/running/parallel_execution.md)

Next: [Reading results and investigating failures](investigating_failures.md)

### Link
- [index](../index.md)
