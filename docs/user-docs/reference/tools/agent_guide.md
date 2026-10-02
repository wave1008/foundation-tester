# Agent Guide: from an app screen to a passing scenario

This page is for **AI coding agents** that write fleetest scenarios through the `ft_*` MCP tools.
It is the short version of the runbook (`.claude/skills/fleetest-scenario/SKILL.md` in the clone);
read the runbook when you need the full rules.

## The loop

1. **Pick the device.** `ft_list_devices`, then pass the same `profile:` (a run profile name) — or
   `udid:` / `port:` / `serial:` — to every `ft_*` call, so exploring and running use one device.
2. **Explore.** `ft_launch` the app, then `ft_snapshot`. Each row is
   `[ref] Type "label" id=… (x,y WxH)`. Move with `ft_tap` / `ft_type` (by `ref` or selector).
   For long lists use `ft_scroll_to` with a selector instead of repeating `ft_swipe`.
   Take a snapshot of every screen you pass — the dry-run checks `#id`s against them.
3. **Draft.** `ft_draft_scenario` turns the operations since the last `ft_launch` into Swift and
   returns it as text (it writes no file). Cut detours with `drop:` / `lastN:`.
   **The expectation blocks come back empty on purpose** — fill them from what the snapshots showed.
4. **Write the file** under `TestProjects/<project>/scenarios/<name>.swift`.
5. **Compile.** `ft_list_scenarios` builds the project and returns compile errors as-is.
6. **Dry-run.** `ft_dry_run` needs no device. A selector syntax error fails it (isError).
   `⚠️` lines (an expectation with no assertion, an `#id` never seen in a snapshot) are not
   failures, but fix them anyway.
7. **Run.** `ft_run_scenario`. A failure is isError and carries the failing step, **the element
   list and a screenshot at the moment of failure**, and the report path. Read the element list
   first — the screenshot cannot give you an `#id`.

## A scenario

```swift
import FTDSL

@TestClass(app: "com.example.app", platform: "ios")
class SignInExample {
    @Test("Signing in shows the home screen")
    func S0010() {
        scenario {
            scene(1, "The sign-in screen opens") {
                condition {
                    launchApp()
                }.action {
                    tap("#btn_signin")
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "Signing in lands on home") {
                action {
                    tap("#field_email")
                    type("#field_email", "user@example.com")
                    ifCanSelect("#btn_dismiss_tips", waitSeconds: 1) {
                        tap("#btn_dismiss_tips")
                    }
                    tap("#btn_submit", scroll: .down)
                }.expectation {
                    select("#txt_title").textIs("Home")
                }
            }
        }
    }
}
```

- `scene` = one screen. `condition` (preconditions) → `action` (operations) → `expectation`
  (checks). An `expectation` without an assertion checks nothing.
- `ifCanSelect` handles a dialog that may or may not appear. `scroll: .down` reaches an element
  below the fold.
- **Do not guess command names.** `ft_dsl_commands` lists every command and its signature; a name
  that is not in that index does not exist.

## Selectors

- Prefer `#id`. A bare label (`"Home"`) matches the whole label exactly; `*text*` is a wildcard
  for dynamic text only.
- `.type[n]` breaks when siblings are added or removed. Scope it instead: `#container >> .button`.
- Never write a selector you have not seen in a snapshot.

## Make it independent of the screen size

- Reach anything below the fold with `scroll:` or `scrollTo` — do not assume it is visible.
- Start and end a swipe on elements that are surely inside the window.
- Do not assume how far one swipe travels, and do not use `notExist` to prove that something
  scrolled away (how many rows stay in the tree depends on the window height).

## When a run fails

| What the failure says | What to do |
|---|---|
| element not found | Look for the element in the element list at failure. A changed `#id` shows up there with its new value; an element that exists but is off screen needs `scroll:` |
| another window was in front of the app | A system alert or overlay swallowed the input. Handle it (`ifCanSelect`, or an alert handler — see the command reference) |
| the app process was not running | The app crashed. Check `ft_logs` before touching the scenario |
| an assertion failed with the actual value | Compare with the element list; fix the expected value only if the app is right |

## Runs the user asks for

`ft_run_scenario` is for checking while you write a scenario; it leaves no result history (`results/`) and no recording.
When the user asks you to run tests, use `ft_start_run`. It starts the same run as `fleetest run --profile` in the
background and returns at once; follow progress and the result with `ft_run_status` (stop it with `ft_stop_run`).
`ft_start_run` may ask the user for approval, depending on their settings. If it is refused, do not work around it
with `fleetest run` in the shell or similar; tell the user the run needs their approval (the approval setting is the
safety line the user chose).
It runs inside the MCP server, so it also works for agents whose shell is sandboxed.

| Request | Tool (arguments) |
|---|---|
| Run (all, a class, one test) | `ft_start_run` (`profile`, and `scenario: ["<Class>[.<method>]"]` if needed) |
| Only what failed last time | `ft_start_run` (`profile`, `failed: true`) |
| Once on every device | `ft_start_run` (`profile`, `broadcast: true`) |
| Result, failed scenarios and their reports | `ft_run_status` |
| Unstable, slower or regressed tests | `ft_results` (`query: "flaky"` / `"slow"` / `"insights"`) |
| The execution log of a run | `ft_results` (`query: "log"`, `runId` default `latest`, optionally `scenario`) |

`ft_results` prints the same text as `fleetest results <query>`. Do not add `app:` to a scenario or point at a bridge port by hand
to run it on every device.

## Pausing or retiring tests

Do not move files into `_disabled/`; mark them. Both marks drop the test from bulk runs; it runs only when named by its exact ID.

- Unfinished: `@Draft("reason")`
- Retired: `@Deleted("reason")`

Both can be put on a class or on an individual `@Test`.

## Naming devices in reports

In reports to the user, do not call a Simulator or Emulator a "physical device". That word means
only a real iPhone / Android connected over USB (`kind: "physical"` in the run profile). When unsure, say "device".

## Writing for specific UI components

If the screen has stock Material3 components (pager, bottom sheet, dropdown menu, date picker,
drawer, pull-to-refresh, snackbar, search bar, …), read the matching section of
[UI component patterns and quirks](../writing/ui_component_patterns.md) before writing. It covers
component-specific patterns — the screen behind a modal drops out of the tree, a field's content is
in `.value`, horizontal containers need `scrollFrame:` — and workarounds for the tool's current
limitations.

## Links

- [MCP server](mcp_server.md)
- [AI assistants other than Claude Code](other_agents.md)
- [Command reference](../../../commands.md)

### Link
- [index](../../index.md)
