# Creating tests

[in Japanese(日本語)](creating_tests_ja.md)

You have an AI assistant create the tests. The AI assistant actually operates the app on a device and
writes the scenario while reading the elements shown on the screen. It never writes buttons or IDs that
are not on the screen from imagination.

The result is a Swift file (scenario) under `TestProjects/<project>/scenarios/`.
You can use it without being able to read its contents, but if you want to check what gets written, see the [reference](#more-details).

## Create an exploratory test

You specify a screen and let the AI assistant decide what to check as well. This suits your first test.

### Prompt for the AI

```text
Create an exploratory test for just the My Shop login screen.
```

The AI assistant operates the login screen, tries invalid input, submitting with empty fields, moving between screens and so on,
and turns the behavior it finds into a scenario. At the end of the work it runs the compile and the verification without a device (dry-run),
runs the scenario on a device, and reports the result.

Here is the result of actually asking this for the sample app ([SUT Store](https://github.com/wave1008/sut-ec-mobile)).

<img src="../images/tutorial/en/explore_result.png" width="720" alt="Exploring the login screen produced five tests (open the screen, submit empty, wrong input, go to sign-up and back, back button), all passing on iOS">

<img src="../images/tutorial/en/ai_workflow.png" width="720" alt="Operate and read the screen, write the scenario, compile, dry-run, run on a device, report the result">

## Turn a fixed procedure into a test

When the steps you want to check are already decided, write the steps and "what must be visible for it to succeed".

### Prompt for the AI

```text
Create an iOS test for My Shop with these steps:
1. Open the first product in the product list
2. Tap "Add to cart"
3. Open the cart screen
Then check that the cart has 1 item, and that its name matches the product you opened from the list.
```

If you do not write "what to check", you may get a test that only performs operations and verifies nothing.
**Always write the success condition.**

## Add to an existing test

### Prompt for the AI

```text
Add a case to the My Shop login test: a password shorter than 8 characters should show an error message.
```

Even if you do not know which file the existing scenario is in, the AI assistant finds it.

If the behavior you ask for is not in the app (in the example above, there is no message specific to passwords under 8 characters
and the same error as a wrong password appears), the AI assistant checks the actual behavior, reports it, and leaves the
decision of whether that matches the specification to you.

## Make a test that runs on both iOS and Android

For an app with the same screens and the same IDs (such as Compose Multiplatform, Flutter, or React Native),
one scenario can run on both OSes.

```text
Make the My Shop login test work on both iOS and Android, then run it on both to confirm.
```

For parts where the screens differ by OS, the AI assistant writes them separately as per-OS branches.

## Handle screens that may or may not appear

Screens that sometimes appear and sometimes do not, such as first-launch guides, announcement dialogs, and OS permission dialogs,
are the biggest cause of unstable tests. When you notice one, mention it in your request.

```text
My Shop sometimes shows a "Spring campaign" dialog right after launch. "Close" at the top right dismisses it.
Update the login test so that it closes the dialog when it appears, then continues.
```

**Include the dialog's name and the label of its close button** (and, if you can, a screenshot of the screen while it is shown).
The AI assistant only writes elements it has seen on the screen into a test, so if the dialog does not appear while it looks,
it ends up relaunching the app again and again without a clue.

## Creating by recording (VSCode)

There is also a way to create tests without an AI assistant. In the "Live Control" tab of the VSCode extension's device monitor,
press "Start Recording", operate the app shown on screen, and then press "Stop Recording"; your
operations become a scenario. A scenario created by recording has no "what must be visible for it to succeed", so

```text
scenarios/Generated/ contains a scenario created by recording. Add checks for what's on screen to each test.
```

ask the AI assistant to finish it like this, and it becomes a complete test. For details, see
[Watch in VSCode](watching_in_vscode.md).

## When it does not go well

| Symptom | What to ask |
|---|---|
| The work drags on or goes off track | Narrow the target again to one screen or one flow. Write the completion condition |
| It is exploring on the wrong device | Specify the run profile's name ("on the devices of the ios-run profile") |
| The test sometimes passes and sometimes fails | "Run this test 5 times, and if some runs fail, investigate the cause" |
| Elements lower on the screen are not reached | "Make it reach elements that are only visible after scrolling" |

## More details

References for when you want to read and write the contents of a scenario (the Swift DSL).

- [Creating a test class](../reference/testclass/creating_testclass.md) and [Test code structure](../reference/testclass/testcode_structure.md)
- [Selector expressions](../reference/selector/selector_expression.md) (how to point at elements on the screen)
- [Writing robust scenarios](../reference/writing/writing_robust_scenarios.md)
- [How to write for each UI component, and its quirks](../reference/writing/ui_component_patterns.md)

Next: [Running tests](running_tests.md)

### Link
- [index](../index.md)
