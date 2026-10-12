# Quality attributes (non-functional requirements)

[in Japanese(日本語)](quality_ja.md)

This page is not about fleetest's features. It is about the qualities that affect how it feels to use and
how far you can trust it: **AI-friendliness, stability, security and privacy**. Each item links to a page with the details.

## AI-friendliness

fleetest is built on the assumption that you use it by asking an AI assistant.

- **Just ask in plain language.**
  Ask "create tests for the login screen" or "find out why this failed", and the AI assistant creates the tests,
  runs them and reports the results. You do not need to read or write test code yourself
  ([Asking the AI assistant](../tutorial/asking_ai.md)).
- **The AI can actually operate the app and read the screen.**
  Through the MCP server, the AI assistant taps and types in the app on the device and receives the screen's
  contents as short text that is easy for an AI to read. Tests are built from the real screen, not from guesses
  ([MCP Server](../reference/tools/mcp_server.md)).
- **The AI can catch its own mistakes.**
  It drafts a test from the steps it performed, then finds mistakes with compilation and dry-run before any device
  is moved ([Agent Guide](../reference/tools/agent_guide.md)).
- **Failures come back in a form the AI can investigate.**
  When a test fails, fleetest returns the failed step along with the list of screen elements and a screenshot
  from that moment. Past results can also be queried by the AI, so you can have it look for unstable or slowed-down
  tests ([Reading Results and Investigating Failures](../tutorial/investigating_failures.md)).
- **Runbooks are included.**
  Runbooks (Claude Code skills) cover installation, creating profiles and creating tests, and the AI assistant
  follows them, pausing for confirmation along the way ([Claude Code Skills](../reference/tools/claude_code_skills.md)).
- **Not tied to one AI.**
  Besides Claude Code, any AI assistant that supports MCP (Codex, Cline, Cursor and others) can use it
  ([AI Assistants Other Than Claude Code](../reference/tools/other_agents.md)).

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

## Automatic data cleanup

- **Unneeded data that builds up on devices and the Mac is cleaned up regularly.**
  Deleting device caches and logs, and resetting the data of an Android Emulator that has grown too large, are
  automated ([Maintenance for long-term use](../in_action/maintenance.md)).

## Reproducibility and cost efficiency

- **Test code is meant to be created with AI, but test execution is not left to AI.**
  The test code follows the same steps every time, so results do not waver and there is no AI charge per run.

## Security

There are mechanisms that limit the risk if harmful code gets mixed into test code.

- **Tests always run inside a sandbox.**
  fleetest limits which files a test can read and write, whom it can talk to and what it can do. For example, important files such as SSH keys and the keychain cannot be read
  ([The sandbox](../security/sandbox.md)).
- **Tests can reach only the destinations you allow.**
  A test can talk to the internet only at the destinations listed in the `allowedDomains` setting
  ([Accessible folders and destinations](../security/access.md)).

## Privacy

- **Data never leaves the fleet you set up with your Macs and devices.**
  No cloud service is accessed.
- **Some features use FM (Foundation Models), Apple's local LLM, but Apple's cloud (Private Cloud Compute) is not used.**
- **Frontier models such as Claude or GPT are recommended for creating tests, but a local LLM can be used when security requirements are strict.**
- **Do not put real passwords in tests.**
  There is a setting (off by default) that masks account values in records, but text visible in screenshots and
  recordings cannot be hidden. Use test accounts.

## Customizability

Test code is plain Swift, so wherever the built-in commands fall short, you can add what you need yourself.
There is no need to modify fleetest itself ([Adding your own features](../reference/writing/extending.md)).

- **Turn frequent steps into your own commands.**
  Wrap repeated steps such as logging in or emptying the cart in a Swift function and call it from any test.
  Give it a description and the AI assistant writing tests will find and reuse it instead of writing the same
  steps again ([Custom Commands](../reference/testclass/custom_commands.md)).
- **Write logic the built-in commands do not have.**
  Any Swift code can go into a test as a single named step.
- **Connect to test data and external servers.**
  Read accounts and test data from files, or call a test API to create the data a test needs.
- **Use libraries and shared components.**
  Add Swift packages to use libraries or your team's shared components in tests.
- **Run setup and cleanup around a test run.**
  Preparing a database or a stub server can happen automatically before and after the run.

What you add also runs inside the sandbox described in the Security section.

## Scaling out

- **Tests can be shared across several devices.**
  Mix Simulators, Emulators and physical devices and run several tests at the same time. One Mac can only
  run so many devices; beyond that, add Macs
  ([Parallel Execution](../reference/running/parallel_execution.md)).
- **You can add Macs too.**
  Send tests to other Macs and share the work among them ([Remote Runners](../fleet/remote_runners.md)).

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
- **What you need**: an Apple silicon Mac. Tested with iOS and Android apps built with the main approaches
  (SwiftUI / UIKit, View/XML, Compose Multiplatform, Flutter, React Native) ([Environment](environments.md)).

### Link
- [index](../index.md)
