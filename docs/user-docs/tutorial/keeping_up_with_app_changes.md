# Keeping Tests Up with App Changes

[in Japanese(日本語)](keeping_up_with_app_changes_ja.md)

Apps keep changing. The work of fixing the tests each time can also be left to the AI assistant.

## Self-healing absorbs small changes

When only a button's ID changes while its visible text (label) stays the same, fleetest's self-healing absorbs it on the spot and the test continues.
The selector of a step that passed is written back to the scenario source automatically at the end of the run (this assumes the project is kept in git), so review the diff and commit.

### Prompt for the AI

```text
In the fleetest test project myshop, review in the git diff the selectors that self-healing wrote back to the scenarios.
Keep the reasonable ones, then run those scenarios and confirm they pass.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

If you run from the VSCode Test Explorer, a notification appears; press "Show Changes" to open the Source Control view, then review the git diff and commit.
To avoid write-back, set `heal` to `false` in the run profile to turn self-healing off.

</details>

## When the screen changes

When the screen layout or the steps themselves change, self-healing can't keep up. Ask while including what the intended change is.

### Prompt for the AI

```text
The My Shop login screen has a new design (the email address and password are now on separate screens).
Update the login-related scenarios in the fleetest test project myshop to match the current screens, then run them to confirm.
Don't rewrite tests that are failing because of an app bug just to make them pass.
```

## When new interruptions appear

When new announcement dialogs, surveys, or OS permission dialogs make many tests fail at once, ask for them to be handled together.

### Prompt for the AI

```text
My Shop now sometimes shows a "What's new" dialog right after launch.
Update every test in the fleetest test project myshop so that, if the dialog appears, it taps "Close" and continues.
```

## Make tests harder to break

### Prompt for the AI

```text
Review the scenarios in the fleetest test project myshop and list anything written in a way that is likely to break when the app's text changes or the screen size differs.
Don't fix anything until I've reviewed the list.
```

The viewpoints are in [Writing robust scenarios](../reference/writing/writing_robust_scenarios.md).

## Tests you no longer use

For tests of a feature whose screen is gone entirely, you can keep them by marking them as "deprecated" instead of deleting them (marked tests run only when you name them explicitly).

### Prompt for the AI

```text
The My Shop coupon screen has been removed. Mark the coupon-related scenarios in the fleetest test project myshop as deprecated.
```

## Learn more

[Self-healing](../reference/running/self_healing.md) / [Creating a test class](../reference/testclass/creating_testclass.md) / [Maintenance for long-term use](../in_action/maintenance.md)

Next: [Watching in VSCode](watching_in_vscode.md)

### Link
- [index](../index.md)
