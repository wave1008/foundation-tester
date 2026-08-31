# About Fleetest

Fleetest is an E2E testing tool for iOS / Android apps. It runs on macOS and is designed to be
used together with a coding agent such as Claude Code.

## Three things packed into the name

**fleetest** is `fleet` + `test` — and at the same time the superlative of *fleet* (swift).

- **fleet** — Tests run in parallel across a **fleet of devices**: simulators, emulators, physical
  devices, and even other Macs over SSH. Scenarios are distributed across the devices
  automatically, which shortens the wall-clock time of a run (up to what the host and the
  devices can sustain).
- **fleetest** — Ordinary playback has no LLM in the loop, so there is no waiting on model
  inference. What bounds a run is the device, not a model.
- **free** — No cloud device farm and no per-run API billing are needed. (The tool is free;
  the Mac, Xcode and the devices you run on are yours.)

## AI writes the tests, code replays them deterministically

Authoring and execution have clearly separated roles.

**AI (or a human) writes the test.** There are three ways to write one, and all of them produce
the same Swift scenario.

- Record your operations in the VSCode extension's live-control panel
- Let an agent write it — it explores the real screens and captures selectors as it goes
- Write it by hand — irregular handling and test data setup are plain Swift

**Code replays it.** Scenarios run deterministically; ordinary playback uses no LLM. Fast,
stable, and CI-friendly.

**AI is used only for a few specific features.** Self-healing of broken selectors, visual
verification of the screen with `screenLooksLike`, and triage of the cause when a step fails.
All of it runs on Apple's on-device model (Foundation Models), so screen data from your app
never leaves your Mac.

## Four entry points

There are four entry points for different uses, but they share one core. A test written through
any of them becomes the same `.swift` file and can be run from any of them.

| Entry point | Suited for |
|---|---|
| **VSCode extension** | Interactive use: device monitor, live control (record → generate), running, results dashboard |
| **MCP server** | Agent-driven work: AI-authored tests, debugging, exploratory testing |
| **CLI** `fleetest` | Scheduled CI / regression runs |
| **Swift DSL** | The test asset itself: `TestProjects/<name>/scenarios/*.swift` |

## How it works

Devices are driven through resident bridges of our own. On iOS it talks over HTTP to an XCUITest
process inside the simulator; on Android it talks to a bridge over adb. There is no dependency on
Appium or any other external driver.

Platform differences end at the driver layer — the replay engine and the Foundation Models calls
are entirely shared between iOS and Android.

### Link
- [index](../index.md)
