# MCP Server

`fleetest-mcp` is a stdio [MCP](https://modelcontextprotocol.io) server that exposes device
operations, scenario execution and scenario authoring as `ft_*` tools for coding agents.
It is the same functionality as the CLI and VS Code extension, called by an agent instead of a
human.

## Setup

The `fleetest` server is registered during installation (`install.sh` / `/fleetest-setup`).
For Claude Code it is written into your work folder's `.mcp.json` with the clone's **absolute path**,
so it starts the same way wherever you open the agent (the first call triggers a build). To add
just the MCP server to a different project — without the VS Code extension or project scaffolding —
see [Claude Code Skills](./claude_code_skills.md) (`/fleetest-mcp`).

**Any other agent works too** (Codex, Cline, …). `fleetest-mcp` is a plain stdio MCP server, so
any MCP-capable client can register it. Follow that client's own configuration format and give it
this launch command (`<ABS_TOOL_ROOT>` is the absolute path of the clone; the TOML form and how to
hand over the runbooks are in [AI assistants other than Claude Code](./other_agents.md)):

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
| `udid` | iOS device UDID — Simulator or physical (from `ft_list_devices`) |
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
(`ft_list_scenarios`, `ft_dry_run`, `ft_run_scenario`, `ft_start_run`) execute the project's scenarios (`.swift`)
as arbitrary Swift code (a dry run executes them too).

- **Scenarios always run inside fleetest's sandbox (macOS Seatbelt)**, whether they are started from MCP, the CLI or
  the extension. Inside the sandbox a scenario:
  - can write only to the report directory, the project's `.fleetest/` and a temporary folder of its own. It cannot write
    the scenario sources, the fleetest clone, or anywhere else in your home folder. Scenario code writes to
    [`TestLog.directoryForLog` / `TestLog.directoryForTemp`](../commands/test_log.md) (`NSTemporaryDirectory()` is not writable).
  - cannot read the usual places for credentials and personal data (`~/.ssh`, `~/.aws`, `~/.config`, `~/.gradle`,
    keychains, browser profiles, cookies, Mail, Messages, shell history and so on).
  - sees only the environment variables fleetest itself uses (`PATH`, `HOME`, `DEVELOPER_DIR`, `ANDROID_HOME`,
    `FT_*` and so on) from the environment fleetest was started in. Tokens in the `env` of `.mcp.json` or in your
    shell do not reach the scenario.
  - can connect only within this Mac (the bridges). Outside connections go through a proxy, and only to the
    domains you allow.
  - cannot launch other apps, or operate the Simulator, a physical iPhone or an Android device beyond the fixed
    operations fleetest uses (fleetest itself performs Simulator, iPhone and Android (adb) operations on the
    scenario's behalf and lets only known shapes through; a scenario cannot connect to the adb server or the
    Emulator console, nor read the adb keys).
- **The sandbox settings live only in `sandbox` in this Mac's `~/.config/fleetest/config.json`** (never in the
  project, because an agent can rewrite the project).

  ```json
  {
    "sandbox": {
      "denyRead": ["~/work/secrets"],
      "allowedDomains": ["api.example.com", "*.example.org"]
    }
  }
  ```

  `denyRead` **adds** places to the built-in list; `allowedDomains` lists destinations scenarios may reach (leave it
  out and nothing outside this Mac is reachable). `"disabled": true` turns the sandbox off on this Mac.
  `"allowDirectAdb": true` lets scenarios use adb and bundletool themselves instead of through fleetest (it opens the
  adb server and Emulator ports and `~/.android`). A scenario can then get out through a shell inside an Emulator and
  reach every connected Android device (the other restrictions stay). It makes no practical speed difference (under
  1 ms per adb call), so use it only when you need it. An unknown key
  or broken JSON stops the scenario from starting with an error. For Claude Code, the installer writes a rule into the
  work folder's `.claude/settings.json` that denies editing that folder.
- **Some things stay outside the sandbox.** A scenario can still connect to services running on this Mac such as the
  bridges (including other devices' bridges and other services listening on this Mac's localhost). It can send the contents of files it could read to a
  device as input to an app. The app under test itself runs outside the sandbox. The setup / teardown scripts that
  `ft_start_run` runs and `Package.swift`, which is evaluated at build time, are not covered by the sandbox.
- **Choose what to approve by what runs outside the sandbox.**

  | Tools that ask for approval | Convenience | What goes past a human |
  |---|---|---|
  | none | never interrupted | nothing (assumes a repository and app you trust) |
  | `ft_start_run` (recommended) | once, when you ask for a test run | setup / teardown scripts, sending a run to another machine |
  | `ft_list_scenarios`, `ft_dry_run`, `ft_run_scenario`, `ft_start_run` | asked at every compile and check while writing scenarios | every scenario execution |

  For Claude Code, the installer writes "allow the fleetest tools (`mcp__fleetest`), ask only before `ft_start_run`
  (`ask`)" into the work folder's `.claude/settings.json` (the recommended shape; remove it from `ask` if you do not
  want the prompt, and later updates will not put it back). It also makes the fleetest clone read-only (reading is
  allowed, editing is denied); this is skipped when the work folder is inside the clone. In Auto mode, the AI decides
  on its own whether to ask, but it judges the tool call, not the contents of the scenarios.
  For Codex, see [AI assistants other than Claude Code](other_agents.md) (`default_tools_approval_mode` for the whole server, `approval_mode`
  under `[mcp_servers.fleetest.tools.<tool name>]` per tool). `writes`, which skips approval only for read-only tools,
  also counts screen operations (taps, typing) as writes, so exploring a screen means dozens of approvals.
- **Each tool declares what it does through MCP annotations.** Clients that decide approval from them treat the
  tools accordingly.

  | Declared as | Tools |
  |---|---|
  | Read-only (`readOnlyHint: true`) | `ft_status`, `ft_list_*`, `ft_snapshot`, `ft_screenshot`, `ft_logs`, `ft_results`, `ft_run_status`, `ft_dsl_commands`, `ft_doctor`, `ft_draft_scenario` |
  | Changes the device's screen or the app's state | taps, typing, swipes and other operations, `ft_launch`, `ft_terminate`, `ft_open_url`, `ft_batch`, `ft_capture_element` (writes a sample into the project) |
  | Cannot be undone (`destructiveHint: true`) | `ft_clear_app_data`, `ft_install`, `ft_stop_run` |
  | Runs the project's code (`destructiveHint: true`, `openWorldHint: true`) | `ft_list_scenarios`, `ft_dry_run`, `ft_run_scenario`, `ft_start_run` |
- **Check the contents of scenarios you receive from others before running them.** The sandbox protects this Mac,
  but it does not stop what is listed above as staying outside, nor operations on the app under test or its accounts
  (deleting, purchasing and so on).
- **`ft_start_run`'s `runner` accepts only registered machine names and `local`.** Raw destinations such as
  `user@host` are refused, so scenarios and profiles are never sent to a machine the user has not registered.
  Register machines with `fleetest remote machines add`. The CLI's `fleetest run --runner` accepts raw destinations too.
- `ft_stop_run` / `ft_run_status` only handle runs that this server started with `ft_start_run`.
- `ft_start_run` passes checked arguments as an array to a fixed command (`fleetest run`); no shell is involved, so
  no arbitrary command can be injected through the arguments. Values of `profile`, `runner`, `scenario` and `folder`
  that start with `-` are refused (`fleetest run` would read them as options, which could get around the `runner`
  restriction above).

## Structured output (opt-in)

Set `FT_MCP_STRUCTURED_CONTENT=1` in the server's environment (the `env` of its MCP entry) to have
`ft_run_scenario`, `ft_dry_run` and `ft_list_scenarios` also return `structuredContent` — a JSON
summary (per-scenario pass/fail and report path, or the scenario list). It is only sent when the
client negotiated MCP 2025-06-18 or later. **Leave it off for Claude Code**: Claude Code shows the
model only `structuredContent` when it is present, so the text notes and the failure screenshot would
no longer reach it.

### Link
- [index](../../index.md)
