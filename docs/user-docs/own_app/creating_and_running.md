# Creating and running tests

[in Japanese(日本語)](creating_and_running_ja.md)

Create a happy-path test for your own app (for example the test project myshop), run it, and choose the smoke tests.

## 1. Create a test

### Prompt for the AI

```text
In the fleetest test project <name>, create one happy-path test (the normal flow) for my app. Do <the screens and the flow>, and check <what must be visible for it to succeed>.
This app sometimes shows a "<dialog name>" dialog right after launch. "<close button label>" dismisses it, so close it when it appears, then continue.
```

For screens that sometimes appear (first-launch guides, announcements, OS permission dialogs), give the name and the close button's label. To check that the screen changed, make the success condition a text that appears only on the destination screen.

More details: [Creating a test class](../reference/testclass/creating_testclass.md) · [Selector expressions](../reference/selector/selector_expression.md) · [Writing robust scenarios](../reference/writing/writing_robust_scenarios.md) · [How to write for each UI component, and its quirks](../reference/writing/ui_component_patterns.md)

## 2. Before you run

An irreversible operation such as an order, submission or registration can happen twice in one run. Find such tests first, and point them at a test counterpart (a payment test mode, staging) before you run.

### Prompt for the AI

```text
In the fleetest test project myshop, find the scenarios that contain irreversible operations such as submitting, purchasing or registering,
and check that they point at a test payment or staging server.
```

## 3. Choose the smoke tests

For smoke, pick just a few of the app's main flows (it launches, you can log in, the main screens open). You can ask the AI assistant which ones to pick.
How to split them into folders and run them is in [Running smoke and regression separately](../tutorial/smoke_and_regression.md).

Next: [Keeping tests up with app changes](keeping_up.md)

### Link
- [index](../index.md)
