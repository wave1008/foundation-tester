# Quick Start

The shortest path from a completed setup to running your first scenario. This assumes
`/ftester:ftester-setup` (see [Getting Started](getting-started.md)) has already been run; if you
haven't set up yet, start there.

## 1. Prerequisite: setup is done

You should already have a work folder with a `TestProjects/` directory (created by
`/ftester:ftester-setup`). If not, go to [Getting Started](getting-started.md) first.

## 2. Prepare a profile

You need an app profile (target app), a machine profile (device), and a run profile (the
combination of app + devices) before you can run anything. Use the `/ftester:ftester-profiles`
skill in Claude Code, or run the underlying command directly:

```bash
ftester profile setup --platform ios --app-id com.example.myapp --auto-device
```

`--auto-device` picks an available simulator/emulator on this machine automatically. See
[Run Profile](./project/run_profile.md) for what a run profile controls once it exists.

## 3. Write one scenario

Any of the following three paths produce the same kind of Swift file under
`TestProjects/<project>/scenarios/`:

- Ask Claude Code to write it (`/ftester:ftester-scenario`) — it explores the real screens with
  you and captures real selectors before writing the file.
- Record it live from the VSCode extension's live-control panel (operate the app; a scenario is
  generated for you).
- Write it by hand.

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

Selectors (`#email`, `#login_btn`, …) must come from the real screen — see
[Selector Expression](./selector/selector_expression.md) or use `/ftester:ftester-scenario`,
which captures them for you.

## 4. Verify without a device (dry-run)

Before touching a device, run a dry-run — it checks selector syntax, unreachable scenes, and
`expectation` blocks with no assertions, in a few seconds:

```bash
ftester run --dry-run --scenario LoginTest
```

## 5. Run it on a device

```bash
# Clone layout (working inside the foundation-tester clone)
swift run ftester run --profile <run-profile-name>

# External package layout (a separate TestProjects/ work folder)
../foundation-tester/.build/debug/ftester run --profile <run-profile-name>
```

`--profile` resolves the app, the devices, and the run-time settings (self-healing, timeouts,
etc.) from the run profile you prepared in step 2.

You can also run it from the VSCode extension: open the **Test Explorer**, find the scenario, and
click **Run** (or **Run (dry-run)** to repeat step 4 from the UI).

## 6. Where results go

Every run writes a Markdown report per scenario to `TestProjects/<project>/reports/`, regardless
of pass/fail. It includes the scene → condition/action/expectation step hierarchy, triage on
failure, screenshots, and self-healing suggestions if applicable.

In VSCode, the Test Explorer shows pass/fail status directly on each test, and you can open the
generated report from there.

### Link
- [index](index.md)
