# Reading Results and Investigating Failures

[in Japanese(日本語)](investigating_failures_ja.md)

Every time you run tests, the results are kept, pass or fail. You can leave the reading to the AI assistant too.
What fleetest records is only the facts: at which stage, which operation, and how it failed. It does not jump to conclusions about causes.

## 1. Have the results summarized

### Prompt for the AI

```text
Summarize the latest run of the fleetest test project myshop. If anything failed, list the failed scenarios and the steps where they failed.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

- Each scenario has a Markdown report under `TestProjects/myshop/reports/`.
- In VSCode, the Test Explorer shows pass/fail directly, and you can open the report from there.
  The command "fleetest: Open Results Dashboard" also shows the run history and success rate.

</details>

## 2. Have the cause of a failure investigated

### Prompt for the AI

```text
Use the reports to find out why scenarios failed in the latest run of the fleetest test project myshop, and report back.
For each one, say whether it looks like an app bug or a problem with how the test is written.
Don't fix the scenarios yet (and don't make them pass by adjusting expected values to match the app).
```

- Always add "don't fix them". If you ask for investigation and a fix at once, a test that failed because of an app bug may get made to pass by adjusting the expected value to match the app.
- Read the report first, then you decide whether to fix it.

What you'll see: the report contains the failed step, the failure message, and the element list and screenshot at the moment of failure (below is from the sample app).

<img src="../images/tutorial/en/report_failure.png" width="600" alt="Excerpt of a failed report: the failed step and its message, the element list at the moment of failure (collapsed), and the screenshot">

### Once you have a hunch about the cause

- An app bug: leave the test as is, and after the app is fixed, check with this prompt.

```text
In the fleetest test project myshop, re-run only the scenarios that failed last time.
```

- The screen changed and the test is outdated: [Keeping up with app changes](keeping_up_with_app_changes.md)
- A dialog that sometimes appears interrupted the test: "When new interruptions appear" in [Keeping up with app changes](keeping_up_with_app_changes.md)
- Not sure:

```text
In the fleetest test project myshop, run the scenario ... 5 times and find out what differs between the runs that fail and the runs that pass. Don't fix it yet.
```

## 3. Find unstable tests

### Prompt for the AI

```text
Go through past results of the fleetest test project myshop and find scenarios that are flaky (sometimes pass, sometimes fail) and scenarios that have been getting slower.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest results flaky --project myshop      # Scenarios that both pass and fail
../foundation-tester/.build/debug/fleetest results insights --project myshop   # Regressions, consecutive failures, scenarios that got slower, bias toward specific devices, etc.
../foundation-tester/.build/debug/fleetest results slow --project myshop       # In descending order of average duration
```

</details>

### What to do once you find one

#### Prompt for the AI

```text
In the fleetest test project myshop, fix the flaky scenario ... following the robust-scenario guidelines (where waits are placed, selectors, how things that may or may not appear are handled).
After fixing it, run it on iOS 5 times in a row and confirm that all of them pass. If any run fails, report which run failed and why.
```

- One pass does not mean it is fixed. Always run it several times in a row.
- A slow Mac makes tests flakier. Turn off "Live Updates" in the Device Monitor and run them again ("When the Mac is slow" in [Watching in VSCode](watching_in_vscode.md)).
- On CI the policy is to find and fix, not to hide it behind retries ([Running on CI](../in_action/ci.md)).

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

There is no option to set a count. Use a shell loop to run the same scenario repeatedly.

```bash
for i in 1 2 3 4 5; do
  ../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario <ClassName> --quiet || echo "failed: run $i"
done
```

`<ClassName>` is the scenario's file name without the extension. Each run ends with a summary line, and a failed run is followed by `failed: run N`.

</details>

## Look back at how a run went

### Prompt for the AI

```text
Show me the execution log of the login test in the most recent run of the fleetest test project myshop, and walk me through what happened at each step.
```

Recording is on by default, and a video is kept for each scenario. You can watch recordings in the "Test Sessions" tab of the VSCode extension ([Watching in VSCode](watching_in_vscode.md)). To save space, ask for this:

```text
In iOS runs of the fleetest test project myshop, keep recordings only for failed scenarios.
```

## When it might be a bug in fleetest itself

If, after having the AI assistant investigate, the cause seems to be on the tool's side, report it to the fleetest developers. The diagnostic information is not sent anywhere.

### Prompt for the AI

```text
Create the diagnostic zip with fleetest doctor --bundle fleetest-diag.zip and list its contents. Also check whether it contains text from the app's screens.
```

Where to report, and what to check before sharing the zip, are in [Troubleshooting](../in_action/troubleshooting.md).

## Learn more

[Test result files](../reference/testclass/test_result_files.md) / [Analyzing results](../reference/running/results_analysis.md)

Next: [Keeping tests up with app changes](keeping_up_with_app_changes.md)

### Link
- [index](../index.md)
