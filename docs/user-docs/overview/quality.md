# Quality attributes (non-functional requirements)

[in Japanese(日本語)](quality_ja.md)

This page is not about fleetest's features. It is about the qualities that affect how it feels to use and
how far you can trust it: **AI-friendliness, stability, security and privacy**. Each item links to a page with the details.

## AI-friendliness

- **Just give the AI assistant instructions in plain language** ("create tests for the login screen",
  "run the tests", "find out why this failed" and so on). You do not need to read or write test code yourself
  ([Asking the AI assistant](../tutorial/asking_ai.md)).
- **When you ask for a test, the AI operates the app through the MCP server, reads the screen, gathers what it
  needs and then writes the test code** ([MCP Server](../reference/tools/mcp_server.md)).

## Automated synchronization and performance optimization

- **Synchronizing with the screen is automatic.**
  Instead of "tap, then wait 3 seconds just in case", fleetest moves on as soon as it sees that the screen
  has stopped moving. You do not need to write or tune waiting times in your tests, and no time is wasted waiting.
- **On iOS Simulators, the in-app engine, which runs fast inside the app, is used alongside to boost speed.**
  The hybrid engine switches between the XCUITest engine and the in-app engine automatically to optimize
  performance ([What is fleetest?](about.md)).

## Parallel test runs on a fleet

- **Tests can run in parallel on a group of Simulators, Emulators and physical devices (a fleet).**
  This makes the most of the processor's multiple cores ([Parallel Execution](../reference/running/parallel_execution.md)).
- **Add a Mac and you can use it as a remote runner over the network.**
  Devices on remote runners can also be added to the fleet
  ([Remote Runners](../fleet/remote_runners.md)).

## Fault tolerance

- **Devices in trouble are recovered automatically.**
  If the connection to a device drops, fleetest tries to restore it.
- **Tests that fail because of a device problem, such as a device freezing partway through a test, are rerun on another device.**
  One spare device is kept on standby among the prepared devices.

## Reproducibility and cost efficiency

- **Test code is meant to be created with AI, but test execution is not left to AI.**
  The test code follows the same steps every time, so results do not waver and there is no AI charge per run.

## Security

There are mechanisms that limit the risk if harmful code gets mixed into test code.

- **Tests always run inside a sandbox.**
  fleetest limits which files a test can read and write, whom it can talk to and what it can do
  ([Checking the sandbox and opening the holes you need](../security/sandbox.md)).
- **Tests can reach only the destinations you allow.**
  A test can talk to the internet only at the destinations listed in the `allowedDomains` setting
  ([Sandbox defaults](../reference/running/sandbox_access.md)).

## Privacy

- **Data never leaves the fleet you set up with your Macs and devices.**
  No cloud service is accessed.
- **Some features use FM (Foundation Models), Apple's local LLM, but Apple's cloud (Private Cloud Compute) is not used.**
- **Frontier models such as Claude or GPT are recommended for creating tests, but a local LLM can be used when security requirements are strict.**

## Customizability

Test code is plain Swift, so wherever the built-in commands fall short, you can add what you need yourself.
There is no need to modify fleetest itself ([Adding your own features](../reference/writing/extending.md)).

- **Turn frequent steps into your own commands.**
  Wrap repeated steps such as logging in or emptying the cart in a single function and call it from any test
  ([Custom Commands](../reference/testclass/custom_commands.md)).
- **Insert any processing before and after tests.**
  For example, you can add setup and cleanup for a database or a stub server.

## Scalability

- **Add Macs or physical devices to the fleet to increase the devices doing the work.**
  Even as your tests grow, you can keep the test time from growing with them.

## Easy to operate

- **Fits into CI.**
  Results come back as an exit code and a JUnit file, which CI tools understand as is
  ([Running on CI](../in_action/ci.md)).
- **Results can be examined later.**
  Run results are recorded, so you can later find which tests often fail and where
  ([Analysing results](../reference/running/results_analysis.md)).
- **You can watch tests as they run.**
  The VSCode extension shows each device's screen and run log live
  ([VS Code Extension](../reference/tools/vscode_extension.md)).
- **Disk cleanup is automatic.**
  Recordings and logs are deleted oldest first as they approach their size limit
  ([Maintenance for long-term use](../in_action/maintenance.md)).

## Easy to adopt

- **No changes to your app.**
  No test components to embed and no test-only build. The app you use in everyday development works as is.
- **Free.** Running tests costs nothing per run (AI assistant fees are separate).
- **What you need**: an Apple silicon Mac. Tested with iOS and Android apps built with the major UI frameworks
  (SwiftUI / UIKit, View/XML, Compose Multiplatform, Flutter, React Native) ([Environment](environments.md)).

### Link
- [index](../index.md)
