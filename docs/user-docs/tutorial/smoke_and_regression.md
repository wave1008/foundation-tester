# Running smoke and regression separately

[in Japanese(日本語)](smoke_and_regression_ja.md)

Split your scenarios into a short set you run every time (smoke) and a set that runs everything (regression). No scenario needs to change.
Here, smoke is the open-product-details test (made in the Quick Start) plus the add-to-cart test, and regression is everything.

## 1. Sort them into folders

### Prompt for the AI

```text
In the fleetest test project project1, create a smoke folder under scenarios/ and move OpenProductDetails.swift and AddToCart.swift into it.
After moving, confirm that it still compiles.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
mkdir TestProjects/project1/scenarios/smoke
mv TestProjects/project1/scenarios/OpenProductDetails.swift TestProjects/project1/scenarios/AddToCart.swift TestProjects/project1/scenarios/smoke/
```

A scenario ID (`ClassName.methodName`) does not change with the folder.

</details>
<br>

Expected result:

- Two Swift files in `scenarios/smoke/`.

## 2. Run by folder (smoke) and run everything (regression)

### Prompt for the AI

```text
With the ios-run profile of the fleetest test project project1, run only the scenarios in the smoke folder.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --folder smoke
```

Give `--folder` the name of a subfolder directly under `scenarios/`. It can be repeated, and it can be combined with `--scenario` and `--failed`.
Without a folder, everything runs.

</details>
<br>

Expected result:

- Only the three scenarios inside `smoke` run (one in the open-product-details test and two in the add-to-cart test).

Next, run everything without naming a folder (regression) and compare how many ran.

```text
With the ios-run profile of the fleetest test project project1, run all scenarios.
```

Next: [Watching in VSCode](watching_in_vscode.md)

### Link
- [index](../index.md)
