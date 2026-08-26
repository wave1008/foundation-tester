# MCP Server

`fleetest-mcp` is a stdio [MCP](https://modelcontextprotocol.io) server that exposes device
operations, scenario execution and scenario authoring as `ft_*` tools for coding agents
(Claude Code and Codex). It is the same functionality as the CLI and VS Code extension, called by
an agent instead of a human.

## Setup

Opening Claude Code at the root of the `foundation-tester` repository registers the `fleetest`
server automatically via the repository's `.mcp.json` (the first call triggers a build). Codex does
not read `.mcp.json`; register the server in `~/.codex/config.toml` instead — see
[Codex](./codex_skills.md), which also covers the sandbox settings the server needs. To add just
the MCP server to a different project — without the VS Code extension or project scaffolding — see
[Claude Code Skills](./claude_code_skills.md) (`/fleetest:fleetest-mcp`).

## Common Arguments

Every device tool accepts the same targeting arguments:

| Argument | Meaning |
|---|---|
| `platform` | `ios` (default) or `android` |
| `project` | Test project name |
| `profile` | Run profile name (`profiles/runs/<name>`) — drives the same device and engine as `ft_run_scenario` |
| `udid` | iOS simulator UDID (from `ft_list_devices`) |
| `serial` | Android device serial |
| `port` | iOS bridge port (default: whichever bridge is already running) |

Once a call names a device explicitly, the server remembers it for later calls that omit all of
these; naming a second device requires future calls to be explicit again.

## Tools

| Tool | Description |
|---|---|
| `ft_status` | Connection check — reports the target device and whether the app session is still in the foreground |
| `ft_doctor` | Foundation Models (FM) availability; when unavailable, lists which features are disabled (self-healing, triage, `screenLooksLike`, occlusion checks) |
| `ft_launch` / `ft_terminate` | Launch or terminate the app |
| `ft_install` | Install the app from a package file (`.app` on iOS, `.apk` on Android) |
| `ft_snapshot` | Element list snapshot (compressed, set-of-mark style); `waitFor` waits for a selector to appear |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_long_press` | Screen operations — tap, type (`pressEnter: true` sends Enter/IME after typing), swipe, long press |
| `ft_scroll_to` | Scroll a container until a selector appears, then return the refreshed element list |
| `ft_batch` | Run several operation/scroll steps in one call under a single approval |
| `ft_rotate` | Rotate the device and return the element list in the new orientation |
| `ft_navigate` | Back / Home / app switcher |
| `ft_open_url` | Deliver a deep link without restarting the app |
| `ft_clear_input` | Clear a text field |
| `ft_clear_app_data` | Reset app data and permissions (iOS: simulator only) |
| `ft_dsl_commands` | DSL command index (names and signatures), for checking a command exists before writing it |
| `ft_double_tap` / `ft_pinch` / `ft_drag` | Double tap, pinch, and arbitrary-direction drag |
| `ft_screenshot` | Screenshot image, for visual inspection |
| `ft_list_scenarios` / `ft_run_scenario` | List scenarios / run one deterministically (auto-builds; compile errors are returned as-is) |
| `ft_dry_run` | Device-free validation: selector syntax, unreachable scenes, assertion-less expectations, unknown `#id`s |
| `ft_list_projects` | List test projects and their run profiles |
| `ft_draft_scenario` | Turn a recorded exploration into a Swift scenario draft (not written to disk) |
| `ft_list_devices` / `ft_list_apps` / `ft_logs` | Device / app / log inventory |

## Physical Devices

Screen-operation tools work the same way on a physical iPhone or Android device. Simulator/
emulator-only operations are routed automatically: `ft_install` uses `devicectl` instead of
`simctl` on a physical iOS device, and `ft_clear_app_data` is unavailable on a physical iOS
device (Android's `pm clear` still works on a physical device). The in-app iOS engine cannot be
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

### Link
- [index](../index.md)
