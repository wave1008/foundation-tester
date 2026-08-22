# ftester (foundation-tester) Documentation

[in Japanese(日本語)](index_ja.md)

ftester is an E2E test tool for iOS / Android apps on macOS. Scenarios are written in a
Shirates-style Swift DSL and replayed deterministically; Foundation Models (on-device) step
in only when a step fails. Tests can be authored by Claude Code (MCP), recorded from the
VSCode extension, or written by hand — all three produce the same `.swift` scenarios.

## Repository

- [foundation-tester](https://github.com/wave1008/foundation-tester)

## Overview

- [What is ftester?](overview/about.md)
- [Environments](overview/environments.md)
- [Getting Started (Installation)](getting-started.md)
- [Quick start](quick-start.md)
- [For Shirates users](overview/for_shirates_users.md)

## Tutorial (Basic)

### Creating project

- [Creating a test project](project/creating_project.md)
- [Profiles (app / machine / run)](project/profiles.md)
- [Run profile settings](project/run_profile.md)

### Creating TestClass

- [Creating a TestClass](testclass/creating_testclass.md)
- [Select and assert](testclass/select_and_assert.md)
- [Test code structure](testclass/testcode_structure.md)
- [Test result files](testclass/test_result_files.md)

### Selector

- [Selector expression](selector/selector_expression.md)
- [Relative selector and scope](selector/relative_selector.md)
- [Typed selector (Sel)](selector/typed_selector.md)
- [Elements inside WebView](selector/webview.md)

### Function/Property

- Tap element
    - [tap, tapWithScroll*, tapWithoutScroll, tapAppIcon](commands/tap.md)
- Select element
    - [select, selectWithScroll*, lastElement](commands/select.md)
- Install and launch app
    - [installApp, removeApp, clearAppData](commands/install_app.md)
    - [launchApp, restartApp, terminateApp, openURL](commands/launch_app.md)
- Navigation
    - [home, back, appSwitcher, rotateTo](commands/navigation.md)
- Swipe/Scroll screen
    - [swipe, swipePointToPoint, swipeElementToElement, swipeBy](commands/swipe.md)
    - [scroll (scrollTo, scrollDown, withScrollDown, scrollFrame, ...)](commands/scroll.md)
    - [flick](commands/flick.md)
    - [Gestures for maps and canvases (doubleTap, pinchIn, pinchOut)](commands/gestures.md)
- Editing and keyboard operations
    - [type](commands/type.md)
    - [clearInput](commands/clear_input.md)
    - [pressEnter, hideKeyboard](commands/press_enter_hide_keyboard.md)
- Asserting existence
    - [exist, notExist, countIs](commands/existence_assertion.md)
- Asserting attribute
    - [Text assertion (textIs, textContains, ...)](commands/text_assertion.md)
    - [Value assertion (valueIs, valueContains, ...)](commands/value_assertion.md)
    - [id assertion (idIs)](commands/id_assertion.md)
    - [State assertion (enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)](commands/state_assertion.md)
- Asserting others
    - [Keyboard assertion (keyboardIsShown, keyboardIsNotShown)](commands/keyboard_assertion.md)
    - [Screen assertion (screenLooksLike)](commands/screen_assertion.md)
    - [App assertion (appIs)](commands/app_assertion.md)
- Asserting any value
    - [Any value assertion (thisIs, thisContains, ...)](commands/any_value_assertion.md)
- Asserting anything
    - [Anything assertion (verify)](commands/verify.md)
- Reading values
    - [Reading values of the grabbed element (.text, .value, .id, lastElement)](commands/reading_values.md)
- Branch
    - [ifCanSelect, ios, android](commands/branch.md)
- Repeating action
    - [repeatWhileCanSelect, doUntilTrue](commands/repeat.md)
- Syncing
    - [wait, waitForDisplay, waitForClose](commands/wait.md)
- Descriptor
    - [group, procedure, setUp, tearDown](commands/descriptors.md)
- Screenshot
    - [screenshot](commands/screenshot.md)
- Handling irregulars
    - [irregularHandler](commands/irregular_handler.md)
    - [suppressHandler, useHandler, disableHandler, enableHandler](commands/suppress_handler.md)
    - [iOS system alerts (iosAlertHandler)](commands/ios_alert_handler.md)

### Running

- [Running scenarios (ftester run)](running/running_scenarios.md)
- [dry-run (No-Load-Run)](running/dry_run.md)
- [Self-healing and the heal cache](running/self_healing.md)
- [Parallel execution](running/parallel_execution.md)
- [Analysing results (ftester results, dashboard)](running/results_analysis.md)

### Tools

- [VSCode extension](tools/vscode_extension.md)
- [MCP server (Claude Code)](tools/mcp_server.md)
- [Claude Code skills](tools/claude_code_skills.md)

## Tutorial (In action)

- [Writing robust scenarios](in_action/writing_robust_scenarios.md)
- [Running on CI](in_action/ci.md)
- [Remote runners](in_action/remote_runners.md)
- [Troubleshooting](in_action/troubleshooting.md)

## Reference

- [DSL command reference (Japanese)](../commands.md)
- [Results JSON schema (Japanese)](../results-json.md)
