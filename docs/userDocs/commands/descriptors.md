# group, procedure, setUp, tearDown

Structuring commands: grouping steps in the report, running arbitrary Swift as one step, and
per-test setup/teardown.

## Functions

| function | description |
|---|---|
| `group("name") { }` | Prefixes the steps inside with `[name]` in the report. Execution and failure semantics are unchanged. |
| `procedure("description") { try await ... }` | Runs arbitrary async Swift as one recorded step. A thrown error fails the scenario. |
| `func setUp()` | Defined on the test class; runs automatically before each `@Test`. |
| `func tearDown()` | Defined on the test class; runs automatically after each `@Test`, **including after a failure**. |

## Example

```swift
@TestClass(app: "com.example.myapp", platform: "ios")
class LoginFlow {
    func setUp() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }

    func tearDown() {
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
- `tearDown()` still runs after a `@Test` fails — use it for cleanup that must happen either
  way (e.g. terminating the app).
- `@Deleted("reason")` and `@Draft("reason")` mark a `@TestClass` or `@Test` as retired or
  in-progress; both are excluded from bulk runs (all-scenarios, folder, class-name) and can
  only be run by an exact ID. See
  [Creating a test class](../testclass/creating_testclass.md) for the full annotation reference.
- fleetest does not have Shirates's `describe` / `caption` / `manual` / `knownIssue`
  annotations — a scene's title string is where that kind of description belongs.

### Link
- [index](../index.md)
