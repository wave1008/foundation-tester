# fleetest mobile Documentation

[in Japanese(日本語)](index_ja.md)

fleetest is an E2E test tool for iOS / Android apps that you use by asking an AI assistant such as
Claude Code in natural language. For the origin of the name and its features, see
[What is fleetest?](overview/about.md).

If you are new, install it with [Getting Started](getting-started.md), then go through the
[Quick start](quick-start.md) and the [Tutorial](#tutorial).

## Repository

- [foundation-tester](https://github.com/wave1008/foundation-tester)

## Overview

- [What is fleetest?](overview/about.md)
- [Environment](overview/environments.md)
- [Getting Started (Installation)](getting-started.md)
- [Quick start](quick-start.md)

## Tutorial

- [Asking the AI assistant](tutorial/asking_ai.md)
- [Preparing the app and devices](tutorial/preparing_app_and_devices.md)
- [Creating tests](tutorial/creating_tests.md)
- [Running tests](tutorial/running_tests.md)
- [Reading results and investigating failures](tutorial/investigating_failures.md)
- [Keeping tests up with app changes](tutorial/keeping_up_with_app_changes.md)
- [Watching in VSCode](tutorial/watching_in_vscode.md)

## Operations

- [Update](update.md)
- [Uninstall](uninstall.md)
- [Running on CI](in_action/ci.md)
- [Remote runners](in_action/remote_runners.md)
- [Setting up a remote runner](in_action/remote_runner_setup.md)
- [Network exposure and security](in_action/network_security.md)
- [Troubleshooting](in_action/troubleshooting.md)
- [Maintenance for long-term use](in_action/maintenance.md)

## Reference

The specification of scenarios (Swift DSL), the CLI and MCP. Use it when you want to read the
scenarios the AI assistant wrote, or to write some yourself.

### Projects and profiles

- [Creating a test project](reference/project/creating_project.md)
- [Profiles (app / run)](reference/project/profiles.md)
- [Run profile settings](reference/project/run_profile.md)

### Creating TestClass

- [Creating a TestClass](reference/testclass/creating_testclass.md)
- [Select and assert](reference/testclass/select_and_assert.md)
- [How text visual verification decides](reference/testclass/text_visual_check.md)
- [Test code structure](reference/testclass/testcode_structure.md)
- [Custom commands](reference/testclass/custom_commands.md)
- [Test result files](reference/testclass/test_result_files.md)

### Selector

- [Selector expression](reference/selector/selector_expression.md)
- [Relative selector and scope](reference/selector/relative_selector.md)
- [Typed selector (Sel)](reference/selector/typed_selector.md)
- [Elements inside WebView](reference/selector/webview.md)

### Function/Property

- Tap element
    - [tap, tapAppIcon](reference/commands/tap.md)
- Select element
    - [select, lastElement](reference/commands/select.md)
    - [Find by image (findImage, findImages, existImage)](reference/commands/find_image.md)
- Install and launch app
    - [installApp, removeApp, clearAppData](reference/commands/install_app.md)
    - [launchApp, restartApp, terminateApp, openURL](reference/commands/launch_app.md)
- Navigation
    - [home, back, appSwitcher, rotateTo](reference/commands/navigation.md)
- Swipe/Scroll screen
    - [swipe, swipePointToPoint, swipeElementToElement, swipeBy](reference/commands/swipe.md)
    - [scroll (scrollTo, scrollDown, withScrollDown, scrollFrame, ...)](reference/commands/scroll.md)
    - [flick](reference/commands/flick.md)
    - [Gestures for maps and canvases (doubleTap, pinchIn, pinchOut, gesture, hold)](reference/commands/gestures.md)
- Editing and keyboard operations
    - [type](reference/commands/type.md)
    - [clearInput](reference/commands/clear_input.md)
    - [pressEnter, hideKeyboard](reference/commands/press_enter_hide_keyboard.md)
- Asserting existence
    - [exist, notExist, countIs](reference/commands/existence_assertion.md)
- Asserting attribute
    - [Text assertion (textIs, textContains, ...)](reference/commands/text_assertion.md)
    - [Value assertion (valueIs, valueContains, ...)](reference/commands/value_assertion.md)
    - [id assertion (idIs)](reference/commands/id_assertion.md)
    - [State assertion (enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)](reference/commands/state_assertion.md)
    - [Image assertion (imageIs)](reference/commands/image_assertion.md)
- Asserting others
    - [Keyboard assertion (keyboardIsShown, keyboardIsNotShown)](reference/commands/keyboard_assertion.md)
    - [Screen assertion (screenLooksLike)](reference/commands/screen_assertion.md)
    - [App assertion (appIs)](reference/commands/app_assertion.md)
- Asserting any value
    - [Any value assertion (thisIs, thisContains, ...)](reference/commands/any_value_assertion.md)
- Asserting anything
    - [Anything assertion (verify)](reference/commands/verify.md)
- Reading values
    - [Reading values of the grabbed element (.text, .value, .id, lastElement)](reference/commands/reading_values.md)
- Sharing values between scenarios
    - [Memo (writeMemo, readMemo, clearMemo, memoTextAs)](reference/commands/memo.md)
    - [Output folder and temporary folder (TestLog)](reference/commands/test_log.md)
- Test data and talking to servers
    - [Test data and accounts (account, data)](reference/commands/dataset.md)
    - [HTTP request (httpRequest)](reference/commands/http_request.md)
- Branch
    - [ifCanSelect, ios, android](reference/commands/branch.md)
- Repeating action
    - [repeatWhileCanSelect, doUntilTrue](reference/commands/repeat.md)
- Syncing
    - [wait, waitForDisplay, waitForClose](reference/commands/wait.md)
- Descriptor
    - [group, procedure, beforeEach, afterEach](reference/commands/descriptors.md)
- Screenshot
    - [screenshot](reference/commands/screenshot.md)
- Handling irregulars
    - [irregularHandler](reference/commands/irregular_handler.md)
    - [suppressHandler, useHandler, disableHandler, enableHandler](reference/commands/suppress_handler.md)
    - [iOS system alerts (iosAlertHandler)](reference/commands/ios_alert_handler.md)

### Running

- [Running scenarios (fleetest run)](reference/running/running_scenarios.md)
- [dry-run (No-Load-Run)](reference/running/dry_run.md)
- [Self-healing](reference/running/self_healing.md)
- [Parallel execution](reference/running/parallel_execution.md)
- [Analysing results (fleetest results, dashboard)](reference/running/results_analysis.md)

### Tools

- [VSCode extension](reference/tools/vscode_extension.md)
- [MCP server](reference/tools/mcp_server.md)
- [Claude Code skills](reference/tools/claude_code_skills.md)
- [AI assistants other than Claude Code](reference/tools/other_agents.md)
- [Agent guide](reference/tools/agent_guide.md)

### Writing scenarios

- [Writing robust scenarios](reference/writing/writing_robust_scenarios.md)
- [UI component patterns and quirks](reference/writing/ui_component_patterns.md)
- [Network access from scenarios](reference/writing/network_access.md)

### Specifications

- [DSL command reference (Japanese)](../commands.md)
- [Results JSON schema (Japanese)](../results-json.md)
- [For Shirates users](overview/for_shirates_users.md)
