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
- **If you run the sample app or your app's server in containers** (optional)
  - Install Apple Container (`brew install container`). You can also have the AI assistant install it in [Preparing the Sample App](sample-app.md)
- **AI assistant**
  - Install an AI assistant that supports MCP (Claude Code, Codex, Cline, Cursor, Copilot, and so on).
    With any of them, you have the assistant carry out the installation.

## 3. Installing fleetest

1. Create a **new, test-only folder** in Finder and open it in VSCode

2. Start your AI assistant and give it this instruction:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

3. When the installation finishes, open the Command Palette in VSCode with shift + command + P and run `Developer: Reload Window`.

4. Click **fleetest mobile** in the status bar at the lower-left corner of VSCode. The device monitor opens.

5. If you use an **AI assistant other than Claude Code**, ask it to "register the MCP server". Then restart the assistant.

6. Ask your AI assistant to "run fleetest doctor and report the result", and confirm that no errors are reported

Once it is installed, prepare the sample app in [Preparing the Sample App](sample-app.md), then create and run a test in the [Quick start](quick-start.md).

## 4. Troubleshooting

If you run into a problem, ask your AI assistant. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

Next: [Preparing the Sample App](sample-app.md)

### Link
- [index](index.md)
- [Preparing the Sample App](sample-app.md)
- [Quick start](quick-start.md)
