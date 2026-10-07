# Helpful features for writing test code

[in Japanese(日本語)](helpers_ja.md)

Because scenarios run inside the sandbox, some everyday Swift habits (writing to the temporary folder, reading
environment variables, talking to the network with `URLSession`) do not work as is. fleetest provides features to use
instead. All of them work inside the sandbox as they are.

| What you want to do | Feature |
|---|---|
| Write and keep files | `TestLog.directoryForLog` / `TestLog.directoryForTemp` |
| Use accounts, passwords and input values | `account()` / `data()` |
| Use CSV, JSON or images as files | `dataFile()` |
| Put photos and videos on the device | `addMedia()` |
| Prepare test data or clean up through an API | `httpRequest` / `fleetestURLSession` |
| Pass values between scenarios | `writeMemo` / `readMemo` |
| Keep secrets out of reports | `redactAccountValues` |
| Use external Swift packages | `fleetestScenarioDependencies` |
| Prepare a DB or stub server around a run | `setup.sh` / `teardown.sh` |

## Writing files (TestLog)

Only the two `TestLog` folders (and below) are writable. You cannot write to `NSTemporaryDirectory()`.

```swift
let csv = TestLog.directoryForLog.appendingPathComponent("prices.csv")     // kept with the report
try? "name,price\n".write(to: csv, atomically: true, encoding: .utf8)

let work = TestLog.directoryForTemp.appendingPathComponent("unzipped")     // deleted at the end of the scenario
```

Details: [Output folder and temporary folder (TestLog)](../reference/commands/test_log.md)

## Accounts and test data (account, data)

Read them from JSON files instead of hard-coding them. Values that may go into the repository go in the project's
`dataset/`; passwords and the like go in this Mac's `~/.config/fleetest/dataset/<project name>/` (overriding per
attribute). Shell environment variables are not passed to scenarios, so put tokens here too.

```swift
select("#login_id").type(account("[account1].id"))
select("#login_password").type(account("[account1].password"))
```

Details: [Test data and accounts (account, data)](../reference/commands/dataset.md)

## Using files (dataFile) and adding photos (addMedia)

Put CSV with many rows, request bodies for APIs and images in the dataset folder as files. The file on this Mac
(`~/.config/fleetest/dataset/<project name>/`) is used if present; otherwise the project's `dataset/`.

```swift
let body = (try? String(contentsOf: dataFile("api/new_order.json"), encoding: .utf8)) ?? ""
addMedia("img/avatar.png")   // for testing photo pickers (not possible on a physical iOS device)
```

`addMedia` can send only files inside the dataset folder.

Details: [Test data and accounts (account, data)](../reference/commands/dataset.md)

## Talking to servers (httpRequest, fleetestURLSession)

Allow the destination in `allowedDomains`, then use `httpRequest`. It already uses the sandbox's proxy.

```swift
let response = httpRequest("https://api.example.com/orders", method: "POST",
                           headers: ["Content-Type": "application/json"],
                           body: #"{"item": "widget"}"#)
response.status.thisIs(201)
```

When you use `URLSession` yourself, use `fleetestURLSession` instead of `URLSession.shared` (a `URLSession` with the
proxy already set).

Details: [HTTP request (httpRequest)](../reference/commands/http_request.md), [Network access from scenarios](../reference/writing/network_access.md)

## Passing values between scenarios (memo)

Pass values prepared in `setUpDevice()` to other scenarios on the same device. You do not need to write and exchange
files yourself.

Details: [Memo (writeMemo, readMemo, clearMemo, memoTextAs)](../reference/commands/memo.md)

## Keeping secrets out of reports (redactAccountValues)

By default, the value in `type(account("[account1].password"))` stays as is in step descriptions, run logs and
reports. Writing `"redactAccountValues": true` in this Mac's `~/.config/fleetest/config.json` replaces values from
`account()` with `***`. Text captured in screenshots cannot be redacted.

Details: [Test data and accounts (account, data)](../reference/commands/dataset.md)

## Using external Swift packages

Packages for generating one-time passwords, processing JSON and so on can be imported from scenarios once you list
them in two places in `Package.swift`: `dependencies:` and `fleetestScenarioDependencies`. Library code you import runs
inside the same sandbox as the scenario (only building the dependencies runs outside, so add only packages you trust).

Details: [Creating a test project](../reference/project/creating_project.md)

## Running something around a run (setup.sh, teardown.sh)

Preparation that cannot be done inside the sandbox, such as a DB or stub server the app under test depends on, goes in
`TestProjects/<project>/workspace/scripts/setup.sh` / `teardown.sh`. They run outside the sandbox at the start and
end of a run (they do not run for MCP's `ft_run_scenario`).

Details: [Adding your own features](../reference/writing/extending.md)

## Use DSL commands to operate devices

If a scenario calls `adb`, `simctl` or `devicectl` directly, fleetest itself runs only fixed forms on its behalf and
refuses the rest. For installing, launching, clearing data or opening URLs, use the DSL commands
([installApp](../reference/commands/install_app.md), [launchApp](../reference/commands/launch_app.md), ...).

### Link
- [index](../index.md)
