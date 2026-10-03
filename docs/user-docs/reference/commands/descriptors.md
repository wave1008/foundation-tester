# group, procedure, beforeEach, afterEach

Structuring commands: grouping steps in the report, running arbitrary Swift as one step, and
per-test setup/teardown.

## Functions

| function | description |
|---|---|
| `group("name") { }` | Prefixes the steps inside with `[name]` in the report. Execution and failure semantics are unchanged. |
| `procedure("description") { try await ... }` | Runs arbitrary async Swift as one recorded step. A thrown error fails the scenario. |
| `func beforeEach()` | Defined on the test class; runs automatically before each `@Test`. |
| `func setUpDevice()` | Defined on the test class; runs **at most once per run, per device, per class** — before `beforeEach()` of the first scenario of that class that lands on the device. Share what it prepares with [`writeMemo` / `readMemo`](memo.md). |
| `func afterEach()` | Defined on the test class; runs automatically after each `@Test`, **including after a failure**. |
| `func tearDownDevice()` | Defined on the test class; runs **once, after the device has finished all of its scenarios in the run** (if at least one scenario of that class ran on the device). Use it to clean up after `setUpDevice()`. |

## Example

```swift
@TestClass(app: "com.example.myapp", platform: "ios")
class LoginFlow {
    func beforeEach() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }

    func afterEach() {
        terminateApp()
    }

    @Test("login succeeds with valid credentials")
    func S0010() {
        scenario {
            group("prepare test data") {
                procedure("seed the account via API") {
                    try await seedTestAccount()
                }
            }
            scene(1, "log in") {
                action {
                    launchApp()
                    tap("#email"); type("user@example.com")
                    tap("#password"); type("secret")
                    tap("#login_btn")
                }.expectation {
                    exist("#welcome_text")
                }
            }
        }
    }
}
```

## Notes

- **`procedure { }` is where a scenario should put code it does not want to run after a
  failure.** Raw Swift inside a block is not skipped when an earlier step in the scene has
  failed, so wrap anything that should not fire on a broken state in `procedure { }` (a
  thrown error there aborts the scenario the same way a failed command does).
- `setUpDevice()` runs in the process of that first scenario only, so **instance properties it sets are not visible to other scenarios** — pass values with `writeMemo` / `readMemo`. If it fails, the remaining scenarios of that class on the same device are recorded as failed without running, and it is never retried on that device within the run.
- `afterEach()` still runs after a `@Test` fails — use it for cleanup that must happen either
  way (e.g. terminating the app).
- `tearDownDevice()` runs in a process of its own and can read the memo. It runs even if `setUpDevice()` failed, but not on a device that dropped out mid-run or when the run is interrupted. Its result goes to the run log and a report and does not count toward the test results.
- `@Deleted("reason")` and `@Draft("reason")` mark a `@TestClass` or `@Test` as retired or
  in-progress; both are excluded from bulk runs (all-scenarios, folder, class-name) and can
  only be run by an exact ID. See
  [Creating a test class](../testclass/creating_testclass.md) for the full annotation reference.
- fleetest does not have Shirates's `describe` / `caption` / `manual` / `knownIssue`
  annotations — a scene's title string is where that kind of description belongs.

### Link
- [index](../../index.md)
