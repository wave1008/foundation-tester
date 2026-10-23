# Checking what a test leaves behind

[in Japanese(日本語)](test_outputs_ja.md)

Running a test leaves reports, results, logs and recordings on your Mac's disk. They contain **the text on the app's
screen** (button labels, values you typed, body text that was shown). This page walks through opening what is left to see
where it is, masking secrets, checking the contents before you send anything out, and deleting what you no longer need.
It assumes you have finished the [Quick Start](../quick-start.md) up to step 7 (creating one scenario and running it).

> Data does not leave your Mac and devices. FM (Apple's on-device model) also runs only on the Mac.
> See "Privacy" in [Quality characteristics](../overview/quality.md). Something leaves only when you send a zip or the like yourself.

## 1. Run one scenario

Run the scenario you created in the Quick Start.

### Prompt for the AI

```text
Run the scenario I created in the Quick Start on iOS.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

</details>
<br>

## 2. Open what was left

Every run adds files in these places (`<project>` is `project1` or similar).

| Where | What | Screen text |
|---|---|---|
| `TestProjects/<project>/reports/` | A Markdown report per scenario (`scenario-*.md`). On a failure it also holds the element list at the moment of failure and a screenshot (`.png`) | Step descriptions contain labels and the values you typed. The element list is the screen text itself |
| `TestProjects/<project>/results/runs/<month>/<runID>/` | `run.json`, `scenarios/<scenarioID>.json` (result JSON) and `events/<scenarioID>.ndjson` (the scenario's execution log) | The execution log contains step descriptions and `print()` output |
| `TestProjects/<project>/results/runs/<month>/<runID>/recordings/` | A recording per scenario | Every character visible on the screen |

The full list of what goes where is in [Test result files](../reference/testclass/test_result_files.md), and how to read the result JSON
is in [Analysing results (fleetest results, dashboard)](../reference/running/results_analysis.md).

### Prompt for the AI

```text
List where the files from this run were left. Open one report and show me the lines in the step descriptions that contain text from the app's screen.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
ls TestProjects/project1/reports/ | tail -3
ls -d TestProjects/project1/results/runs/*/* | tail -1
../foundation-tester/.build/debug/fleetest results log latest
```

`results log latest` prints the per-scenario execution log of the latest run. The step lines show the labels that were tapped and
the text that was typed. A report reads fine when opened in VSCode.

</details>
<br>

Expected result:

- The steps in the report contain text from the app's screen, such as `tap "Login"`.
- You can play recordings in the "Test Sessions" tab of the VSCode extension.
- They show the screen text as it was.

## 3. Mask secrets

Secrets a scenario uses, such as a login password, can be masked in the strings that appear in reports when you read them with
`account()` ([Test data and accounts](../reference/commands/dataset.md)). Nothing is masked by default. Compare the unmasked
and the masked state one after the other.

First, make the scenario use `account()`. Write the real values, such as the password, yourself in
`~/.config/fleetest/dataset/<project>/accounts.json`, which exists **only on this Mac** (it does not go into the repository).

### Prompt for the AI

```text
Change the login scenario to read the ID and the password from account("[account1].id") and account("[account1].password").
Don't create accounts.json (I will write the values).
```

Next, run it unmasked and confirm that the password stays in the output as it is.

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
grep -rl 'the-password-value' TestProjects/project1/reports/ TestProjects/project1/results/ | head
```

Replace `the-password-value` with the real value you wrote in `accounts.json`.

Then write the following in the machine settings `~/.config/fleetest/config.json` **yourself** (create the file if it does not exist), and run again.

```json
{ "redactAccountValues": true }
```

A person at this Mac writes the machine settings by hand. Do not have the AI assistant write them
(Claude Code gets a setting at install time that refuses edits to this folder). The list of setting keys is in
[Machine settings (config.json)](../reference/project/machine_settings.md).

Finally, run `grep` against the new run.

```bash
grep -rn '\*\*\*' TestProjects/project1/reports/ | tail -3
```

Expected result:

- In the new report, execution log and result JSON, the password is `***`.
- **Text captured in screenshots and recordings is not masked**, however. Open a screenshot or recording of a screen that shows the password field in plain text and the value is visible.
- There is no way to erase text inside pixels, so do not use production credentials.

## 4. Check the contents before sending anything out

To report a problem, you bundle diagnostics into a zip and attach it. Check what is in the zip before you share it.

### Prompt for the AI

```text
Make a diagnostic zip with fleetest doctor --bundle fleetest-diag.zip and list its contents with unzip -l.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest doctor --bundle fleetest-diag.zip
unzip -l fleetest-diag.zip
unzip -p fleetest-diag.zip | grep -a -c 'Login'    # count occurrences of text from the app's screen (a label)
```

Replace `Login` on the last line with text that appears on your app's screen.

</details>
<br>

Expected result:

- The zip holds bridge and other logs, the results of the most recent runs (3 by default, including each scenario's execution log), and the tool and OS versions.
- If the count is not 0, text from the app's screen is in the zip.
- The command sends nothing anywhere.
- Something leaves only when you attach the zip, so always check the contents before you share it ("Reporting a problem" in [Troubleshooting](../in_action/troubleshooting.md)).

## 5. Delete it

Look at the amount first, then delete the accumulated recordings, reports and logs.

### Prompt for the AI

```text
Show me how much fleetest clean --dry-run would delete. If that looks fine, run fleetest clean.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest clean --dry-run
../foundation-tester/.build/debug/fleetest clean
```

</details>
<br>

Expected result:

- `--dry-run` lists the targets without deleting anything.
- `clean` sweeps each category that is over 90% of its retention limit back down to 90%, oldest first.
- If nothing has reached its limit, nothing is deleted.
- What is never deleted is the record of results (the JSON with pass/fail and durations) ("Keeping disk space free" in [Maintenance for long-term use](../in_action/maintenance.md)).

## Things to know

- Recordings, reports and execution logs over the limit are deleted automatically in the background each time a test finishes.
- To stop recording, set `record` to `false` in the run profile ([Run profile settings](../reference/project/run_profile.md)).

<br>

Next: [Maintenance for long-term use](../in_action/maintenance.md)

### Link
- [index](../index.md)
