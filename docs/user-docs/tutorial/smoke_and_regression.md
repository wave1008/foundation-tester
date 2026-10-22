# Running smoke and regression separately

[in Japanese(日本語)](smoke_and_regression_ja.md)

Split your scenarios into a short set you run every time (smoke) and a set that runs everything (regression). No scenario needs to change.

## 1. Sort them into folders

### Prompt for the AI

```text
In the fleetest test project myshop, create a smoke folder under scenarios/ and move the login check and the top screen check scenarios into it.
After moving, confirm that it still compiles.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
mkdir TestProjects/myshop/scenarios/smoke
mv TestProjects/myshop/scenarios/Login.swift TestProjects/myshop/scenarios/smoke/
```

A scenario ID (`ClassName.methodName`) does not change with the folder.

</details>
<br>

## 2. Run by folder

### Prompt for the AI

```text
With the ios-run profile of the fleetest test project myshop, run only the scenarios in the smoke folder.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --folder smoke
```

Give `--folder` the name of a subfolder directly under `scenarios/`. It can be repeated, and it can be combined with `--scenario` and `--failed`.
Without a folder, everything runs.

</details>
<br>

What you'll see: only the scenarios inside `smoke` run.

## 3. Re-run only what failed

### Prompt for the AI

```text
In the fleetest test project myshop, re-run only the scenarios that failed in the last run, with the same profile.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --failed
```

Results are recorded per profile, so run it with the same profile as last time.

</details>
<br>

## 4. Take out tests you no longer use or have not finished

### Prompt for the AI

```text
In the fleetest test project myshop, add @Draft("reason") to the unfinished scenario "Checkout" so it is left out of full runs.
For a scenario that is no longer used, add @Deleted("reason") instead.
```

- A marked scenario is left out of full runs, folder runs, and runs that name only a class. It runs only when you give its exact scenario ID.
- `@Draft` is for unfinished scenarios, `@Deleted` for ones no longer used (the code stays, so bringing it back is just removing the mark).

For details, see "Common options" (`--scenario`) in [Running scenarios (fleetest run)](../reference/running/running_scenarios.md).

## 5. Put it on CI

### Prompt for the AI

```text
Create two CI jobs for the fleetest test project myshop.
One runs with --folder smoke every time, the other runs without it at night.
```

Next: [Running on CI](../in_action/ci.md)

### Link
- [index](../index.md)
