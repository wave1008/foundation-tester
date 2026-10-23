# Keeping tests up with app changes

[in Japanese(日本語)](keeping_up_ja.md)

When the screens of your own app (for example the test project myshop) change, bring the tests in line with the current screens.

## 1. When the screens or the steps change

When the screen layout or the steps themselves change, self-healing can't keep up. Ask while including what the intended change is.

### Prompt for the AI

```text
The My Shop login screen has a new design (the email address and password are now on separate screens).
Update the login-related scenarios in the fleetest test project myshop to match the current screens, then run them to confirm.
Don't rewrite tests that are failing because of an app bug just to make them pass.
```

## 2. When more interrupting screens appear

When new announcement dialogs, surveys, or OS permission dialogs make many tests fail at once, ask for them to be handled together.

### Prompt for the AI

```text
My Shop now sometimes shows a "What's new" dialog right after launch.
Update every test in the fleetest test project myshop so that, if the dialog appears, it taps "Close" and continues.
```

Minor changes such as a screen ID having changed are absorbed by self-healing: [Self-healing](../reference/running/self_healing.md)

Related:

- [Maintenance for long-term use](../in_action/maintenance.md)
- [Self-healing](../reference/running/self_healing.md)

### Link
- [index](../index.md)
