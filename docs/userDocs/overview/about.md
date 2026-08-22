# About Ftester

Ftester is a macOS-only E2E testing tool for iOS / Android apps, built around Claude Code.

## Design philosophy: "AI writes the tests, code replays them deterministically"

- **Generation**: recording your operations in the VSCode extension's live-control panel
  generates a **Swift test scenario (a Shirates-style DSL)**. More complex scenarios can be
  written by Claude Code (via MCP) or by hand. Irregular handling and test data setup can be
  written directly in Swift.
- **Execution**: scenarios run deterministically, without an LLM in the loop — fast, stable, and
  CI-friendly.
- **AI steps in only on failure**: locator self-healing (with a heal cache), visual verification
  of screenshots (multimodal), and failure triage with a repair suggestion. **All of this runs
  on-device** — screen data from your app never leaves your Mac.

## Four entry points

The same core (Swift DSL + AppDriver + StepExecutor + a Foundation Models agent) is exposed
through four entry points suited to different uses. The UI is consolidated in the VSCode
extension.

| Entry point | Launch | Suited for |
|---|---|---|
| **CLI** `ftester` | `swift run ftester ...` (clone), or the built `.build/debug/ftester` | scheduled CI / regression runs (deterministic, free, exit code) |
| **VSCode extension** | the VSCode extension (device monitor, live control, dashboard) | interactive use: running/debugging scenarios, live control (record → generate), device monitor, results dashboard |
| **MCP server** | started automatically by Claude Code | agent-driven work: AI-authored tests, debugging, exploratory testing |
| **Swift DSL** | `TestProjects/<name>/scenarios/*.swift` | the test asset itself — saved and run the same way no matter which entry point created it |

## Role division

**Exploration and judgment (intelligence) belong to the agent; operating, executing, and
verifying (determinism) belong to ftester.** Tests are authored either by recording live control
in the VSCode extension (which converts operations into a Swift scenario) or by Claude Code
(via MCP) for more complex cases. Once the Swift scenario exists, it is replayed deterministically
by the CLI or CI.

## Architecture

```
ftester CLI / MCP ──(subprocess)──▶ ftester-scenarios-<project> (discovers/runs a project's scenarios)
      │                                        │  FTDSL   (Swift DSL: @TestClass/@Test macros, commands, reporting)
      │                                        │  FTAgent (Foundation Models: visual verification / healing / triage)
      │                                        │  FTCore  (step model / AppDriver abstraction / StepExecutor)
      │                                        ▼
      ├─ HTTP (localhost:8123) ──▶ a resident XCUITest process inside the iOS simulator
      │                            (WebDriverAgent-style, dependency-free custom bridge)
      └─ adb forward ⇄ resident bridge ──▶ Android emulator / physical device
```

- The only platform boundary is the `AppDriver` protocol — the Foundation Models agent and the
  replay engine are entirely shared between iOS and Android.
- Snapshots are filtered on the driver side and converted into a compressed text form like
  `[3] Button "Log In" id=login_btn` (to work within the on-device model's token budget).

### Link
- [index](../index.md)
