# Getting Started (Installation)

[in Japanese(日本語)](getting-started_ja.md)

How to install fleetest.

## 1. Environment

For the supported macOS, Xcode, Android SDK and other requirements, see [Environment](overview/environments.md).

## 2. Before you start

- **If you test iOS**
  - Install Xcode and the iOS Simulator runtime
- **If you test Android**
  - Install Android Studio (Android SDK)
- **VSCode and Node.js**
  - Install VSCode and Node.js v24 or newer (npm v11 or newer), which are needed to build and install the VSCode extension
- **AI assistant**
  - Install an AI assistant that supports MCP (Claude Code, Codex, Cline, Cursor, Copilot, and so on).
    With any of them, you have the assistant carry out the installation.

## 3. Installing fleetest

1. Create a **new, test-only folder** and open it in VSCode

2. Start your AI assistant and give it this instruction:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

3. When the installation finishes, run `Developer: Reload Window` in VSCode. Also quit your AI assistant (including
   Claude Code) and open a new session in this folder. If asked whether to use the MCP server `fleetest`, allow it
   (the `ft_*` tools and skills registered by the installation are available from the new session)

4. Click **fleetest mobile** in the status bar at the lower-left corner of VSCode. The device monitor opens.

5. If you use an **AI assistant other than Claude Code**, ask it to "register the MCP server". Then restart the
   assistant and open a new session in this folder (this enables the `ft_*` tools used to explore screens and run scenarios).
   For details, see "Register the MCP server" in [AI Assistants Other Than Claude Code](reference/tools/other_agents.md).

6. Ask your AI assistant to "run fleetest doctor and report the result", and confirm that no errors are reported

The installation creates a `foundation-tester` folder next to your work folder. In this documentation,
`../foundation-tester/.build/debug/fleetest` in the commands you type by hand refers to the `fleetest` inside it.

Once it is installed, create and run a test in the [Quick start](quick-start.md).

## 4. Troubleshooting

If you run into a problem, ask your AI assistant. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

Next: [Quick start](quick-start.md)

### Link
- [index](index.md)
- [Quick start](quick-start.md)
