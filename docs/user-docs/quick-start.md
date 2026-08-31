# Quick Start

The shortest path from a completed setup to running your first scenario. If you don't have a
work folder with `TestProjects/` yet, run `/fleetest:fleetest-setup` from
[Getting Started](getting-started.md) first.

## 1. Prepare the profiles

A run needs three profiles — an app profile for the target app, a machine profile for the
devices, and a run profile that combines the two. Use `/fleetest:fleetest-profiles` in your
agent, or create them directly with a command:

```bash
fleetest profile setup --platform ios --app-id com.example.myapp --auto-device
```

`--auto-device` picks an available simulator/emulator on this machine. With this command the
run profile is named after the platform (`ios` here), and on completion the tool prints the
`fleetest run` command to use next — copy it. See [Profiles](./project/profiles.md) for the
details.

## 2. Write one scenario

There are three ways, and all of them produce the same kind of Swift file under
`TestProjects/<project>/scenarios/`:

- Ask your agent (`/fleetest:fleetest-scenario`). It explores the real screens and captures
  selectors for you
- Record it in the VSCode extension's live-control panel. Operate the app and a scenario is
  generated
- Write it by hand

A minimal login scenario looks like this:

```swift
import FTDSL

@TestClass
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

Selectors (`#email` and the like) must come from the real screen. If you write them by hand,
see [Selector Expression](./selector/selector_expression.md).

## 3. Verify without a device (dry-run)

Before touching a device, run a dry-run. It catches selector syntax errors, unreachable scenes,
and `expectation` blocks with no assertions, in a few seconds:

```bash
fleetest run --dry-run --scenario LoginTest
```

## 4. Run it on a device

```bash
# Clone layout (working inside the foundation-tester clone)
swift run fleetest run --profile ios

# External package layout (a separate work folder with TestProjects/)
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` takes the name of the run profile from step 1 (`ios`, as created by the command
above; if you passed `--run <name>`, use that name). The app, the devices, and the run-time
settings are all resolved from it.

From VSCode, open the **Test Explorer**, pick the scenario, and click **Run**.

## 5. Read the results

Every run writes a Markdown report per scenario to `TestProjects/<project>/reports/`, pass or
fail. It contains the result of each step with screenshots, and on failure a triage of the
cause and any self-healing suggestions.

In VSCode, the Test Explorer shows pass/fail on each test, and you can open the report from
there.

### Link
- [index](index.md)
