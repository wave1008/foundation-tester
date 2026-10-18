# Running smoke and regression separately

[in Japanese(日本語)](smoke_and_regression_ja.md)

Once you have a handful of scenarios, split them into a short set you run every time (smoke) and a set that runs everything (regression).
You do not need to change any scenario. You only sort them into folders.

## 1. Sort them into folders

Create a folder directly under `scenarios/` and move the representative scenarios into it (for example, one that logs in and reaches the main screens).

### Prompt for the AI

```text
Create a smoke folder under TestProjects/project1/scenarios/ and move the login check and the top screen check scenarios into it.
After moving, confirm that it still compiles.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
mkdir TestProjects/project1/scenarios/smoke
mv TestProjects/project1/scenarios/Login.swift TestProjects/project1/scenarios/smoke/
```

A scenario ID (`ClassName.methodName`) does not change with the folder.

</details>
<br>

## 2. Run by folder

### Prompt for the AI

```text
With the fleetest ios-run profile, run only the scenarios in the smoke folder.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --folder smoke
```

Give `--folder` the name of a subfolder directly under `scenarios/`. It can be repeated, and it can be combined with `--scenario` and `--failed`.
Without a folder, everything runs.

</details>
<br>

What you see: only the scenarios inside `smoke` run.

## 3. Re-run only what failed

### Prompt for the AI

```text
Re-run only the scenarios that failed in the last run, with the same profile.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --failed
```

Results are recorded per profile, so run it with the same profile as last time.

</details>
<br>

## 4. Take out tests you no longer use or have not finished

Mark the class or method of a scenario you do not want in the regression yet. A marked scenario is left out of full runs, folder runs, and runs
that name only a class. It runs only when you give its exact scenario ID.

- `@Draft("reason")`: unfinished (you will use it later).
- `@Deleted("reason")`: no longer used. The code stays, so bringing it back is just removing the mark.

### Prompt for the AI

```text
Add @Draft to the unfinished scenario "Checkout" so it is left out of full runs.
```

How this relates to choosing what to run is in "Common options" (`--scenario`) in [Running scenarios (fleetest run)](../reference/running/running_scenarios.md).

## 5. Put it on CI

On CI, run smoke every time and everything at night. Make two jobs, one with `--folder smoke` and one without, and run both periodically
([Running on CI](../in_action/ci.md)).

Next: [Running on CI](../in_action/ci.md)

### Link
- [index](../index.md)
