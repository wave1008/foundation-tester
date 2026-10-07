# Adding your own features

When the built-in commands are not enough, you can add features inside your own project without modifying fleetest
itself. There are five main ways to do it. All of them are written in scenarios (`.swift`) or in files of your test project.

| What you want | How | Details |
|---|---|---|
| Bundle steps you repeat | A Swift function (custom command) | [Custom commands](../testclass/custom_commands.md) |
| Run something the DSL has no command for, as one step | `procedure { }` | [Descriptors](../commands/descriptors.md) |
| Use test data or talk to external servers | `account()` / `data()` / `dataFile()` / `httpRequest` | [Test data and accounts](../commands/dataset.md), [HTTP request](../commands/http_request.md) |
| Use a library or share common code | Add a dependency to `Package.swift` | [Creating a test project](../project/creating_project.md) |
| Prepare a database or stub server around a run | Start/end scripts | [Running scripts before and after a run](#running-scripts-before-and-after-a-run) on this page |

## 1. Bundle steps into functions

Steps that come up again and again (logging in, preparing a starting state, routine operations on a screen) go into
**plain Swift functions**. Adding `@FTCommand("description")` lists the function in the command index (`ft_dsl_commands`),
so the AI assistant that writes scenarios reuses it instead of writing the same steps by hand again. The index holds only
the name, call shape and summary, and is returned only to the AI assistant on this Mac (nothing goes outside, and the
function does not become runnable through MCP).

```swift
@FTCommand("Log in with email and password and go to the home screen")
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

Helpers that work on a grabbed element can be written in `extension FTElement`, so they chain like
`select("#x").tapAndConfirm("#y")`.

Common uses:

- **Functions that build an app-specific state**: "logged in", "empty cart", "first-run tutorial done" — keep your
  team's conventions in one place.
- **Grouping by screen**: split functions into files per screen (close to the Page Object pattern). `@FTCommand` can
  only be put on top-level functions and on methods inside an `extension`, not inside a `class` / `struct`.
- **Operating common components**: date pickers, partial swipes, custom multi-touch built with
  [`gesture`](../commands/gestures.md), and so on. Component quirks are in
  [UI component patterns and quirks](ui_component_patterns.md).

The report lists the individual commands inside the function, not the function name. To show them as one unit,
wrap them in `group("name") { }`.

## 2. Run code the DSL has no command for, as one step

Inside `procedure("description") { ... }` you can write any Swift (including `try` / `await`), and it is recorded in
the report as a single step. Throwing inside it stops the scenario, just like a failed command.

```swift
procedure("Create a test order through the API") {
    try await seedTestOrder()   // an async function you wrote
}
```

To verify values that do not depend on the screen (API responses, computed values), use the
[`thisIs` family](../commands/any_value_assertion.md) (for example `response.status.thisIs(201)`).

- Always wrap code that must not run after an earlier step failed in `procedure { }` (plain Swift outside it runs even
  if an earlier step has failed).
- In-app notices and campaigns that may or may not appear are closed automatically if you declare an
  [`irregularHandler`](../commands/irregular_handler.md) in `beforeEach()`. fleetest does not resend an operation
  that the interruption may have swallowed, so write the recovery in a function if you need one. **Only do this for
  operations that are safe to repeat (such as a tap that moves to another screen).** Resending a submit or a purchase
  can run it twice.
- Per-test setup and cleanup go in `beforeEach()` / `afterEach()`; preparation and cleanup that should run once per
  device go in `setUpDevice()` / `tearDownDevice()`.

## 3. Use test data and talk to external servers

| Function | Use it for |
|---|---|
| `account()` / `data()` | Reading accounts and input values from JSON. Keep passwords in this Mac's settings, not in the repository |
| `dataFile()` | Using CSV, JSON, images and other files as files |
| `addMedia()` | Adding photos and videos to the device's photo library (not possible on a physical iOS device) |
| `httpRequest` / `fleetestURLSession` | Creating test data through an API, cleaning up, reading server-side state |
| [`writeMemo` / `readMemo`](../commands/memo.md) | Passing values prepared in `setUpDevice()` to other scenarios |

Common uses:

- Create users or orders through an API before the test, and delete them in `afterEach()`
- Fetch a verification email or one-time password from an inbox API and type it in
- Compare a value shown on screen with the value on the server

By default, scenarios cannot reach anything outside the Mac. Allow the destinations in this Mac's settings first
([Network access from scenarios](network_access.md)).

## 4. Add libraries and shared code

External Swift packages (one-time password generation, cryptography, JSON handling, ...) and your own targets shared
between several test projects can be imported from scenarios once you list them in two places of `Package.swift`:
`dependencies:` and `fleetestScenarioDependencies`. See "Adding dependencies for your scenarios" in
[Creating a test project](../project/creating_project.md).

Building the added dependencies (including macros and build plugins) runs outside the sandbox. Add only packages you trust.

## Running scripts before and after a run

To start a database or stub server that the app under test depends on before a run, and clean it up afterwards,
put scripts in the test project's workspace.

| File | When it runs |
|---|---|
| `TestProjects/<project>/workspace/scripts/setup.sh` | At the start of the run, before any device is touched |
| `TestProjects/<project>/workspace/scripts/teardown.sh` | At the end of the run |

- **If the file is there, it runs** (there is nothing to set in a profile). If it is not, nothing happens.
- **If `setup.sh` exits with a non-zero status, the run stops** (no scenario runs). `teardown.sh` still runs in that
  case. A failing `teardown.sh` only produces a warning; it does not turn the result red.
- Without the execute permission the script is started with `/bin/sh`. With it, the shebang is honoured (you can write
  it in Python, for example).
- There is no timeout. Each time the script produces no output for more than 60 seconds, a one-line warning is printed.
- The script receives the environment variables `FT_HOOK` (`setup` / `teardown`), `FT_WORKSPACE`, `FT_PROJECT`,
  `FT_PROFILE`, `FT_REPORT_DIR`, `FT_IOS_DEVICES` and `FT_ANDROID_DEVICES` (device names separated by spaces). The
  variables are set even when they have no value. The Emulator's adb serial and the Simulator's UDID are not passed
  (call `adb devices` and the like yourself if you need them).
- For a run sent to a [remote runner](../../in_action/remote_runners.md), the scripts run on the runner machine.
  Processes started over ssh may be unable to reach other addresses on the same machine (container virtual networks,
  the LAN), so connect to dependent services through `127.0.0.1`.
- The scripts run outside the sandbox. They run with `fleetest run` and the MCP tool `ft_start_run`, but not with
  `ft_run_scenario` (the MCP tool that runs a single scenario).

## Feeding results into your own systems

- **CI**: pass the JUnit XML from `fleetest run --junit <path>` and the exit code to your CI ([Running on CI](../../in_action/ci.md)).
- **Aggregation and notifications**: read the results JSON ([schema, Japanese](../../../results-json.md)) and feed it to
  your own dashboard or chat notifications. What `fleetest results` can aggregate is in
  [Analysing results](../running/results_analysis.md).

## What you cannot add

| What you cannot do | Why / what to do instead |
|---|---|
| New kinds of operations on the device, or new information read from it | These are driver and bridge features, so fleetest itself has to change. Only what can be written by combining built-in commands is in your hands |
| Write arbitrary files or read secrets in your home folder from a scenario | Scenarios run inside a sandbox. Write through [`TestLog.directoryForLog` / `directoryForTemp`](../commands/test_log.md) |
| Start other apps or use adb / simctl directly from a scenario | fleetest itself performs a fixed set of operations on the scenario's behalf. adb can be opened with `allowDirectAdb` in this Mac's settings (see the sandbox section of [MCP server](../tools/mcp_server.md)) |
| Run a custom command through `ft_batch` | `ft_batch` only runs built-in commands. Write custom commands in a scenario `.swift` file and run that |
| Read shell environment variables (tokens and so on) in a scenario | Scenarios only receive the variables fleetest uses. Put secrets in this Mac's `account()` files |

### Link
- [index](../../index.md)
