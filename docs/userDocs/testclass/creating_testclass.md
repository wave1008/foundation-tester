# Creating a Test Class

A test scenario is a Swift file that describes a `@TestClass` with one or more `@Test`
methods. This page covers where to put the file and the minimal shape it needs.

## Where the file goes

Place `.swift` files under `TestProjects/<project>/scenarios/` (any subfolder is fine,
e.g. `scenarios/Login/`). Running `swift build` (or any `ftester run`) auto-discovers new
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

## setUp / tearDown

```swift
class LoginTest {
    func setUp() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }
    func tearDown() {
        // cleanup that must always run
    }

    @Test("...")
    func S0010() { scenario { /* ... */ } }
}
```

`setUp()` and `tearDown()` run automatically around every `@Test` in the class.
**`tearDown()` still runs even after a failure** — it is the place to put cleanup that must
not be skipped when a scenario is aborted mid-way.

## Marking work in progress or retired tests

- `@Draft("reason")` marks a test as not yet finished. It stays visible in listings as
  "in progress" but is excluded from full runs, folder runs, and class-name runs; it can
  still be run by its exact ID.
- `@Deleted("reason")` marks a test as retired the same way (excluded from bulk runs, still
  runnable by exact ID). The code stays in the file, so un-deleting is just removing the
  annotation.

Both can be attached to the class or to an individual `@Test` method.

### Link
- [index](../index.md)
