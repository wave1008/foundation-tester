# About Fleetest

Fleetest is an E2E testing tool for mobile apps. It is designed to be used from an AI assistant
such as Claude Code.

## Three things packed into the name

- **fleet**
  - Tests run in parallel on a **fleet** — a set of devices such as simulators, emulators and physical devices.
- **fleetest**
  - **fleetest** is the superlative of the English word **fleet** (fast). Fleetest is tuned to run fast both on a single device and in parallel.
- **free**
  - It is open source, so you can get it for free. It also runs entirely locally on your own Mac, with no charges when running tests. (Excluding the cost of your AI assistant.)

## AI writes the test code

The AI assistant writes the tests. What it produces is test code.

When you give the AI assistant an instruction, it drives the app through the CLI or MCP to gather the information it needs, and test code is written in a dedicated DSL.

## Test code runs the tests deterministically

The test code is what runs the tests.

Tests can be run deterministically rather than probabilistically.
Results are stable, runs are fast, and there are no charges.

## Optimized with custom drivers

Fleetest implements its own custom drivers for both iOS and Android and optimizes them. It does not depend on existing general-purpose drivers such as Appium, which leaves it free to make its own improvements.

## Hybrid driver for the iOS Simulator

The hybrid driver, designed for the iOS Simulator, is one of Fleetest's distinctive mechanisms. It automatically switches between a fast in-app driver and a general-purpose XCUITest driver.

- **In-app driver**
  - Injected into the process of the app under test when the app launches. With no cross-process round trip, it runs fast.
- **XCUITest driver**
  - Handles operations outside the app under test. Operations the in-app driver cannot perform are routed here.

| Example operation | Driver used |
|---|---|
| Reading the screen, text entry, taps | in-app |
| Reading and tapping OS system alerts | XCUITest |
| Home screen, app switcher, other apps | XCUITest |

## No changes to your app

- There is no library to link into your app and no test-only build to produce. The debug build of the app you already use works as is.

## Automatic settling after each action

- Settling after an action (waiting for screen transitions to finish) is done automatically inside the driver. This keeps tests less flaky than ad-hoc synchronization where the user tunes sleep durations.

## Fully local execution

- Tests can be run entirely locally on a Mac. Your app and screen data never leave your local network, which makes Fleetest easy to adopt in projects with high security requirements, such as those where cloud services are restricted. With a local LLM, even writing the tests can be kept fully local.



### Link
- [index](../index.md)
