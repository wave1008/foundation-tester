# Creating a Test Class

A test scenario is a Swift file that describes a `@TestClass` with one or more `@Test`
methods. This page covers where to put the file and the minimal shape it needs.

## Where the file goes

Place `.swift` files under `TestProjects/<project>/scenarios/` (any subfolder is fine,
e.g. `scenarios/Login/`). Running `swift build` (or any `fleetest run`) auto-discovers new
files — there is no registration step.

## Minimal example

```swift
import FTDSL

@TestClass                                      // target app is resolved from the run profile
class LoginTest {

    @Test("Can log in with a valid email and password")
    func S0010() {
        scenario {
            scene(1, "Log in") {
                condition {
                    launchApp()
                }.action {
                    tap("#email"); type("test@example.com")
                    tap("#password"); type("password123")
                    tap("#login_btn||Log In")
                }.expectation {
                    exist("#welcome_text||Welcome")
                }
            }
        }
    }
}
```

- `import FTDSL` is required.
- `@TestClass` marks the class. **`app:` is normally omitted** — the target app is resolved
  from the run profile (app profile → running platform's `ios.app`/`android.app`), which is
  what lets the same scenario run against different bundle IDs on iOS and Android. Add
  `@TestClass(platform: "ios")` (or `"android"`) only when the class only makes sense on one
  OS; a run that doesn't cover that OS records it as skipped, not failed.
- `@Test("description")` marks a test method. **Method names follow `S0010`, `S0020`, …**
  (increments of 10, so a step can be inserted later without renaming everything). The
  scenario ID used everywhere (reports, `--scenario`, CI) is `ClassName.MethodName`.
- The body is `scenario { scene(n, "title") { condition { }.action { }.expectation { } } }`
  — see [Test code structure](./testcode_structure.md) for what each block means and how
  chaining works.
- Commands (`tap`, `type`, `exist`, …) are **synchronous, non-throwing free functions**. No
  `try`/`await` and no closure argument (`{ it in }`) are needed — they implicitly act on the
  current execution context.

## beforeEach / afterEach

```swift
@TestClass
class LoginTest {
    func beforeEach() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }
    func afterEach() {
        // cleanup that must always run
    }

    @Test("...")
    func S0010() { scenario { /* ... */ } }
}
```

`beforeEach()` and `afterEach()` run automatically around every `@Test` in the class.
**`afterEach()` still runs even after a failure** — it is the place to put cleanup that must
not be skipped when a scenario is aborted mid-way.

`func setUpDevice()` (optional) runs **at most once per run, per device, per class**, before
`beforeEach()` of the first scenario of that class that lands on the device — for preparation that
should not repeat for every test (for example switching the app's language). Each scenario is
its own process, so instance properties set there are visible only to that first scenario; share
values with `writeMemo` / `readMemo` (see [memo](../commands/memo.md)).

`func tearDownDevice()` (optional) runs **once, after the device has finished all of its scenarios
in the run**, if at least one scenario of that class ran on the device — for cleaning up what
`setUpDevice()` prepared (it runs even if `setUpDevice()` failed). It does not run on a device that
dropped out mid-run or when the run is interrupted. Its result is written to the run log and a
report, but it does not count toward the test results.

## Marking work in progress or retired tests

- `@Draft("reason")` marks a test as not yet finished. It stays visible in listings as
  "in progress" but is excluded from full runs, folder runs, and class-name runs; it can
  still be run by its exact ID.
- `@Deleted("reason")` marks a test as retired the same way (excluded from bulk runs, still
  runnable by exact ID). The code stays in the file, so un-deleting is just removing the
  annotation.

Both can be attached to the class or to an individual `@Test` method.

### Link
- [index](../../index.md)
