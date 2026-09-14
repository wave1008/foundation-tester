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
never leaves your Mac. **Apple's cloud (Private Cloud Compute) is never used**
(see [Requirements](environments.md)).

## Four entry points

There are four entry points for different uses, but they share one core. A test written through
any of them becomes the same `.swift` file and can be run from any of them.

| Entry point | Suited for |
|---|---|
| **VSCode extension** | Interactive use: device monitor, live control (record → generate), running, results dashboard |
| **MCP server** | Agent-driven work: AI-authored tests, debugging, exploratory testing |
| **CLI** `fleetest` | Scheduled CI / regression runs |
| **Swift DSL** | The test asset itself: `TestProjects/<name>/scenarios/*.swift` |

## iOS runs on a hybrid engine

On an iOS simulator, Fleetest keeps two bridges up at once and picks one for each operation.

- **In-app bridge (primary)** — Injected into the app's process when the app launches, it reads
  the screen and performs taps and text entry from inside the app. With no cross-process round
  trip it is faster: in Fleetest's own E2E runs (a Compose Multiplatform app, 40 scenarios,
  8 devices in parallel), the total scenario time dropped from 394 s with XCUITest alone to
  254 s — about 36% shorter.
- **XCUITest bridge (fallback)** — The OS's automation, running outside the app. Only operations
  the in-app bridge fundamentally cannot reach are routed here.

| When | Path used |
|---|---|
| Taps, text entry, reading the screen | in-app |
| Home screen, app switcher | XCUITest |
| When another app (home screen, Settings, …) is opened | XCUITest (back to in-app when you return to your app) |
| OS system alerts (`iosAlertHandler`) | XCUITest |
| Gestures the in-app bridge cannot perform on Compose / Flutter screens, such as long press | XCUITest |
| A WebView inside Compose / Flutter | Read in-app; taps are real XCUITest touches |

### Why it matters

- **No paths in your scenarios** — Test tools that have both an inside-the-app path and an
  outside-the-app path usually leave the choice to the test author, who writes it out through
  separate APIs or context switches. In Fleetest, the tool decides at run time whether an
  operation can be done in-app. Only operations the bridge has declared "not possible for this
  app", or that actually answer "not possible", are routed to XCUITest. Which operations the
  in-app bridge can perform depends on the app's UI framework (SwiftUI, UIKit, Compose
  Multiplatform, Flutter, React Native), but your scenarios never have to spell that difference
  out.
- **No changes to your app** — The in-app bridge is injected at launch, so there is no test
  library to link into the app and no test-only build to produce. Your usual simulator build
  (`.app`) works as is.
- **Never fired twice across paths** — Only operations known to be fundamentally impossible
  in-app are rerouted. An operation that may or may not have landed is never re-fired through the
  other path (so that a send or a purchase cannot happen twice).
- **Exploration and tests see the same thing** — The MCP server (agent-driven exploration) runs
  with the same engine setup as the run profile, so "it worked while exploring but the scenario
  fails" is much less likely.

### Scope

- The hybrid engine is used only on iOS simulators. A physical iOS device cannot take the injected
  bridge, so it runs on XCUITest alone.
- Android has no engine choice (it runs on a single bridge over adb).
- To run on XCUITest alone, set `iosInappEngine` to `false` in the run profile
  (see [Run profile settings](../project/run_profile.md)).

## How it works

Devices are driven through resident bridges of our own. On iOS it talks over HTTP to two of them —
an in-app bridge injected into the app and an XCUITest process inside the simulator (the hybrid
engine above); on Android it talks to a bridge over adb. There is no dependency on
Appium or any other external driver.

Platform differences end at the driver layer — the replay engine and the Foundation Models calls
are entirely shared between iOS and Android.

### Link
- [index](../index.md)
