# Asking the AI assistant

[in Japanese(日本語)](asking_ai_ja.md)

fleetest is used by **asking an AI assistant such as Claude Code in natural language**. You do not need to read or write scenarios (the Swift files the AI assistant writes) or MCP tools yourself.
If you have not run anything yet, go through the [Quick Start](../quick-start.md) first.

## What you can ask for

- Add devices → [Preparing devices](preparing_app_and_devices.md)
- Read the server declaration and check it starts → [Checking the server](preparing_app_server.md)
- Create or extend tests → [Creating tests](creating_tests.md)
- Run tests → [Running tests](running_tests.md)
- Summarize results and investigate failures → [Read results and investigate failures](investigating_failures.md)
- Run by folder → [Running smoke and regression separately](smoke_and_regression.md)

## Patterns for asking

- **Narrow the target**: limit each request to one screen or one flow of operations.
- **Add the OS and device**: writing the run profile name (such as `ios-run`) is the most reliable.
- **Write the completion condition**: say where to stop, for example "stop once you've told me the file name of the new scenario".
- **Make the request independent of the conversation**: instead of "with the app from before", write the app name (SUT Store) or the screen name.
- **Keep the judgment with the human**: separate the investigation from the fix.

```text
Find out why the tests in the fleetest test project project1 failed and report back. Don't fix the scenario yet.
```

AI is not used to replay a finished test (it behaves the same way every time).

You can also use other AI assistants: [AI assistants other than Claude Code](../reference/tools/other_agents.md)

Next: [Preparing devices](preparing_app_and_devices.md)

### Link
- [index](../index.md)
