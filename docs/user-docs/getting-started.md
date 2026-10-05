# Getting Started (Installation)

How to install Fleetest.

## 1. Environment

For the supported macOS, Xcode, Android SDK and other requirements, see [Environment](overview/environments.md).

## 2. Before you start

- **If you test iOS**
  - Install Xcode and the iOS Simulator runtime
- **If you test Android**
  - Install Android Studio (Android SDK)
- **AI assistant**
  - Install an AI assistant that supports MCP (Claude Code, Codex, Cline, Cursor, Copilot, and so on).
    With any of them, you have the assistant carry out the installation.

## 3. Installing Fleetest

1. Create a **new, test-only folder** and open it in VSCode

2. Start your AI assistant and give it this instruction:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

3. When the installation finishes, run `Developer: Reload Window` in VSCode

4. Click **fleetest mobile** in the status bar at the lower-left corner of VSCode. The device monitor opens.

5. If you use an **AI assistant other than Claude Code**, ask it to "register the MCP server". Then restart the
   assistant and open a new session in this folder (this enables the `ft_*` tools used to explore screens and run scenarios).
   For details, see "Register the MCP server" in [AI Assistants Other Than Claude Code](reference/tools/other_agents.md).

Once it is installed, create and run a test in the [Quick start](quick-start.md).

## 4. Troubleshooting

If you run into a problem, ask your AI assistant. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

### Link
- [index](index.md)
- [Quick start](quick-start.md)
