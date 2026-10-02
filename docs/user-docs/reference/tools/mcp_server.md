# MCP Server

`fleetest-mcp` is a stdio [MCP](https://modelcontextprotocol.io) server that exposes device
operations, scenario execution and scenario authoring as `ft_*` tools for coding agents.
It is the same functionality as the CLI and VS Code extension, called by an agent instead of a
human.

## Setup

The `fleetest` server is registered during installation (`install.sh` / `/fleetest:fleetest-setup`).
For Claude Code it is written into your work folder's `.mcp.json` with the clone's **absolute path**,
so it starts the same way wherever you open the agent (the first call triggers a build). To add
just the MCP server to a different project — without the VS Code extension or project scaffolding —
see [Claude Code Skills](./claude_code_skills.md) (`/fleetest:fleetest-mcp`).

**Any other agent works too** (Codex, Cline, …). `fleetest-mcp` is a plain stdio MCP server, so
any MCP-capable client can register it. Follow that client's own configuration format and give it
this launch command (`<ABS_TOOL_ROOT>` is the absolute path of the clone; the TOML form and how to
hand over the runbooks are in [Other agents](./other_agents.md)):

```json
"fleetest": {
  "command": "bash",
  "args": ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

`bash -c` is enough: `mcp-server.sh` itself prepends `/opt/homebrew/bin:/usr/local/bin` to PATH, so the
server finds the Swift/Xcode toolchain even when the client starts it with a minimal PATH. Do not use
`-l` (a login shell): any `echo` in `~/.bash_profile` lands on stdout and breaks the JSON-RPC handshake. `FT_TOOL_ROOT` points at the bridge assets, which is a
different location from the working directory (your test package).

## Common Arguments

Every device tool accepts the same targeting arguments:

| Argument | Meaning |
|---|---|
| `platform` | `ios` (default) or `android` |
| `project` | Test project name |
| `profile` | Run profile name (`profiles/runs/<name>`) — drives the same device and engine as `ft_run_scenario` |
| `udid` | iOS device UDID — simulator or physical (from `ft_list_devices`) |
| `serial` | Android device serial |
| `port` | iOS bridge port (default: whichever bridge is already running) |
| `allowVersionSkew` | Operate even when the bridge's protocol version does not match the tool's (default off = refused; every response that went through carries a warning) |

Once a call names a device explicitly, the server remembers it for later calls that omit all of
these; naming a second device requires future calls to be explicit again.

## Tools

| Tool | Description |
|---|---|
| `ft_status` | Connection check — reports the target device and whether the app session is still in the foreground |
| `ft_doctor` | Foundation Models (FM) availability; when unavailable, lists which features are disabled (`screenLooksLike`, occlusion checks). Self-healing does not use FM and is unaffected |
| `ft_launch` / `ft_terminate` | Launch or terminate the app |
| `ft_install` | Install the app from a package file (`.app` on iOS, `.apk` or a split `.apks` bundle on Android) |
| `ft_snapshot` | Element list snapshot (compressed, set-of-mark style); `waitFor` waits for a selector to appear |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_long_press` | Screen operations — tap, type (`pressEnter: true` sends Enter/IME after typing), swipe, long press |
| `ft_scroll_to` | Scroll a container until a selector appears, then return the refreshed element list. `scrollFrame:` takes the selector of a container marked `scroll`, or the **ref of any element** (its frame becomes the swipe area — for Compose chip rows and carousels) |
| `ft_batch` | Run several operation/scroll steps in one call under a single approval |
| `ft_rotate` | Rotate the device and return the element list in the new orientation |
| `ft_navigate` | Back / Home / app switcher |
| `ft_hide_keyboard` | Close the soft keyboard (Android only; on iOS use `ft_type` with `pressEnter`) |
| `ft_open_url` | Deliver a deep link without restarting the app |
| `ft_clear_input` | Clear a text field |
| `ft_clear_app_data` | Reset app data and permissions (on a physical iOS device it falls back to uninstall + install, using the path from `ft_install` or `packagePath:`) |
| `ft_dsl_commands` | DSL command index (names and signatures), for checking a command exists before writing it |
| `ft_double_tap` / `ft_pinch` / `ft_drag` | Double tap, pinch, and arbitrary-direction drag. On iOS a Compose app ignores the double tap on a physical device or with `xcuitest`, so use `ft_pinch` when the goal is zooming in ([gestures](../commands/gestures.md)) |
| `ft_gesture` | Replay several fingers' timed paths as one continuous touch sequence (fingers never lift between segments) — for a pattern-lock swipe, a long-press that then drags, or a custom multi-finger gesture; absolute coordinates only, no ref/selector form |
| `ft_screenshot` | Screenshot image, for visual inspection |
| `ft_capture_element` | Saves an element as a sample image of an image classifier and reports the training check (samples for `checkIsON` / `imageIs`; see [imageIs](../commands/image_assertion.md)) |
| `ft_list_scenarios` / `ft_run_scenario` | List scenarios / run deterministically (auto-builds; compile errors are returned as-is). A class name as `id` runs every scenario of the class except `@Deleted`/`@Draft`, like `fleetest run`. `profile:` cannot be combined with `port`/`serial`/`platform`/`udid`. **Unlike `fleetest run` it does not run the profile's setup/teardown scripts, send the device home first, or record into `results/`** (use the CLI for a full run). It installs the app only on iOS with a `profile:` whose app has `autoInstall` (copied into the workspace, then installed when the installed copy is out of date); otherwise install it with `ft_install`. **A failure comes back as isError** with the failing step, the element list and screenshot at the moment of failure (first failed scenario only), and the report path |
| `ft_start_run` / `ft_run_status` / `ft_stop_run` | The real run, same as `fleetest run --profile`. `ft_start_run` starts it in the background and returns at once (`profile` required; `scenario` / `folder` are arrays; `failed`, `broadcast`, and `runner` to send this run to another machine — a registered machine name or `local`); `ft_run_status` returns progress and the result (runID, pass/fail, reports of failed scenarios, the tail of the log). Stop it with `ft_stop_run` (SIGTERM). Includes result history (`results/`), recordings and the setup/teardown scripts. It runs inside the MCP server, so agents whose shell is sandboxed (such as Codex by default) can use it too. One run at a time per server |
| `ft_results` | The run-results history, same text as `fleetest results <query>` (no JSON). `query` is required: `list`, `summary`, `flaky`, `trend` (needs `scenario`), `devices`, `slow`, `insights` or `log` (a run's per-scenario execution log; `runId`, default `latest`). Optional: `since` (default `90d`; not for `log`), `scenario`, `limit` (`list` / `slow`), `minRuns` (`flaky`). Reads files only, so it works for agents whose shell is sandboxed (such as Codex by default) |
| `ft_dry_run` | Device-free validation: fails (isError) on selector syntax errors; flags assertion-less expectations and unknown `#id`s as ⚠️ lines (warnings, not failures). For a scenario that declares no platform, `platform:` (default ios) picks the `ios { } / android { }` branch and the `#id` ledger |
| `ft_list_projects` | List test projects and their run profiles |
| `ft_draft_scenario` | Turn a recorded exploration into a Swift scenario draft (not written to disk) |
| `ft_list_devices` / `ft_list_apps` / `ft_logs` | Device / app / log inventory. `ft_list_devices`'s `profile:` narrows the list to that run profile's devices; devices that live on another machine are named but not listed |

## Physical Devices

Screen-operation tools work the same way on a physical iPhone or Android device. Simulator/
emulator-only operations are routed automatically: `ft_install` uses `devicectl` instead of
`simctl` on a physical iOS device, and `ft_clear_app_data` wipes the data by uninstall + install
(using the path from the last `ft_install`, or `packagePath:`) on a physical iOS device (Android's
`pm clear` still works on a physical device). After dismissing a system alert on SpringBoard,
`ft_launch bundleId: <app> resume: true` returns to the app without terminating it (xcuitest
engine / Android). The in-app iOS engine cannot be
injected into a physical device, so it is never selected there.

## iOS Engine Selection

Passing `profile` makes a tool follow that run profile's engine (matching what a real run would
use). Without `profile`, tools follow whichever bridge is already connected on the target port —
if the in-app bridge is running, tools use it hybrid-style (in-app first, falling back to
XCUITest for operations the in-app engine can't perform: Home/app switcher/drag/coordinate long
press); with only the XCUITest bridge running, tools use that directly. A physical device always
uses the XCUITest engine.

## Role Split

The tools intentionally do not include an "explore" tool: exploration and judgment stay with the
calling agent (it already has a snapshot and operation primitives to explore with), while
`fleetest` supplies determinism — operate, replay, verify.

## Sandbox and approval

The MCP server runs **outside** the agent's shell sandbox. Tools that build and run
(`ft_list_scenarios`, `ft_dry_run`, `ft_run_scenario`, `ft_start_run`) therefore execute the project's code outside
the sandbox: `Package.swift`, the scenarios (`.swift`), and, for `ft_start_run`, the run profile's setup / teardown
scripts.

- **Choose what to approve by what runs outside the sandbox.** If MCP tools pass without approval, code the agent
  wrote into the work folder (for example by following instructions hidden in the app's screen) runs outside the
  sandbox with no human check. When the agent types `fleetest run` in its shell, the sandbox or the approval prompt
  stops it there.

  | Tools that ask for approval | Convenience | What goes past a human |
  |---|---|---|
  | none | never interrupted | nothing (assumes a repository and app you trust) |
  | `ft_start_run` (recommended) | once, when you ask for a test run | setup / teardown scripts, sending a run to another machine |
  | `ft_list_scenarios`, `ft_dry_run`, `ft_run_scenario`, `ft_start_run` | asked at every compile and check while writing scenarios | every execution of code outside the sandbox |

  For Codex, see [Other agents](other_agents.md) (`default_tools_approval_mode` for the whole server, `approval_mode`
  under `[mcp_servers.fleetest.tools.<tool name>]` per tool). `writes`, which skips approval only for read-only tools,
  also counts screen operations (taps, typing) as writes, so exploring a screen means dozens of approvals.
- **`ft_start_run`'s `runner` accepts only registered machine names and `local`.** Raw destinations such as
  `user@host` are refused, so scenarios and profiles are never sent to a machine the user has not registered.
  Register machines with `fleetest remote machines add`. The CLI's `fleetest run --runner` accepts raw destinations too.
- `ft_stop_run` / `ft_run_status` only handle runs that this server started with `ft_start_run`.
- `ft_start_run` passes checked arguments as an array to a fixed command (`fleetest run`); no shell is involved, so
  no arbitrary command can be injected through the arguments.

## Structured output (opt-in)

Set `FT_MCP_STRUCTURED_CONTENT=1` in the server's environment (the `env` of its MCP entry) to have
`ft_run_scenario`, `ft_dry_run` and `ft_list_scenarios` also return `structuredContent` — a JSON
summary (per-scenario pass/fail and report path, or the scenario list). It is only sent when the
client negotiated MCP 2025-06-18 or later. **Leave it off for Claude Code**: Claude Code shows the
model only `structuredContent` when it is present, so the text notes and the failure screenshot would
no longer reach it.

### Link
- [index](../../index.md)
