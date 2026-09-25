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

## Links

- [MCP server](mcp_server.md)
- [Other agents](other_agents.md)
- [Command reference](../../commands.md)

### Link
- [index](../index.md)
