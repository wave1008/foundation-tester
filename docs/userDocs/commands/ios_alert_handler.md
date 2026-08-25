# iosAlertHandler

Announces one upcoming iOS system alert (permission prompt, ATT, "Open in …?") and the button
to press on it.

## Functions

| function | description |
|---|---|
| `iosAlertHandler(alert:, button:)` | Registers one upcoming system alert. `alert:` (which alert, matched against its title) is required. Both `alert:` and `button:` use selector matching syntax (`\|\|` for alternatives, `*` for the match mode). Registers are consumed on press: register again for a second alert. `hybrid` engine only. |

## Example

```swift
iosAlertHandler(alert: "*Photo Library*", button: "Don't Allow")
iosAlertHandler(alert: "*wants to track*||*トラッキング*",
                 button: "Allow||許可")                              // both locales
```

## Notes

### Why this exists

Permission prompts, "Open in …?", and similar system alerts are drawn by SpringBoard, a
separate process — they never appear in the app's own accessibility tree, so
[`irregularHandler`](./irregular_handler.md) cannot see or close them.

| engine | how to handle alerts |
|---|---|
| **hybrid** (run profile default) | Write them normally — `tap("Allow")`, `exist(...)`, `ifCanSelect(...)` all reach across to SpringBoard when the app itself cannot resolve the selector. Nothing closes automatically unless you register it with `iosAlertHandler`. |
| **xcuitest alone** | Cannot resolve SpringBoard-side selectors. Run alert-handling scenarios with hybrid instead. |
| **inapp alone** | Same limitation (only sees the process it is injected into). |

The only alert closed automatically without any declaration is `openURL`'s first-time
confirmation.

### Registering

- **`alert:` is required.** The button label alone does not say which window it belongs to —
  without a title match, the tool could press a button on an unrelated alert (a different app's
  permission request queued to the front).
- Both fields use the same matching syntax as selectors: bare = exact match, `x*` = prefix,
  `*x` = suffix, `*x*` = contains. Alert titles embed the app's display name
  ("\"MyApp\" Would Like to Access…"), so `alert:` is written `*x*` in practice.
  `#id` / `.type` are not accepted (they have no meaning against a SpringBoard title).
- **One call announces one alert.** The registration is consumed once a matching alert is
  pressed; register again to handle a second alert. Register before the action that triggers
  the alert — `setUp()` works, registering it once per `@Test` (same lifetime as
  `irregularHandler`).
- **Registrations are tried in order**, and only pressed when the scenario's own requested
  element could not be resolved on either the app side or SpringBoard side — an alert the
  scenario is operating directly (`tap("Allow")`, `ifCanSelect`) is never taken from it.
- **A registration is also consulted when `ifCanSelect` does not resolve** — so a chain like
  the one below still gets past an alert sitting on top of it, instead of the whole chain
  reading "not met" and the alert being pressed too late:

  ```swift
  ifCanSelect("#btn_start||Get Started") { tap("#btn_start||Get Started") }
  ifCanSelect("#btn_agree||I Agree") { tap("#btn_agree||I Agree") }
  ```

- **Labels match exactly, and the tool never guesses a default button.** Which button is the
  "yes" answer is context-dependent (permission prompts have variants like "Allow Once" /
  "Allow While Using App" / "Don't Allow") and both wording and order vary by locale and OS
  version. Only the labels you write are pressed — no partial matching either, so
  `button: "Allow"` never presses "Don't Allow" by accident. Register the reject-side label the
  same way to auto-decline instead.
- **Pressing an alert is recorded in the run log**, including which button was pressed —
  permissions have lasting effect, so a silent auto-press would be a trap later. This also
  covers presses on alerts unrelated to the app under test (another app's queued permission
  request that surfaced in front).

### While a system alert covers the app

This only applies while an `iosAlertHandler` registration is still pending. When an alert is
covering the app, operations and assertions against the app do not proceed — the tool waits for
the alert to clear (or be closed by a registered button), and fails with
`failureKind=system-ui-covered` if it never does:

```
❌ 6. [action] tap "#btn_something"
   system UI is covering the app ("MyApp" Would Like to Access the Photo Library).
   The in-app engine could still reach the app, but a person could not, so the step was not
   performed. None of the registered iosAlertHandler entries matched a button on it.
   Buttons on this alert: "Select Photos" / "Allow Full Access" / "Don't Allow".
   Register the one you want pressed with iosAlertHandler(...), or dismiss it in the scenario.
```

- The failure message lists the alert's actual buttons — since labels match exactly, this is
  the way to learn the correct string without capturing a fast-vanishing alert on video.
- This exists because the in-app engine's tap is a direct call, not an OS touch event — it
  would otherwise reach the app underneath a covering alert, something a real person could not
  do. Android is not affected (its element tree is rooted at the active window, so covered app
  elements simply drop out of the tree).
- Elements the app itself is presenting (a modal it drew) are unaffected — only OS-drawn UI
  covering the app triggers this.
- A passing assertion is checked the same way: if it turned green while covered, the tool tries
  to clear the cover and re-checks on the clear screen before accepting it.

### Consequences of leaving an alert on screen

- **A scenario that triggers an alert must close it within that same scenario.** SpringBoard
  draws it, so it survives `terminateApp()` and even `removeApp()` — it stays on screen for
  whatever runs on that device next, and every following scenario on it hits the covering
  failure above.
- **A leftover alert survives across runs, too.** A warning is printed at the start of a run if
  a device already has one on screen.
- **`clearAppData()` resets permissions**, so the same prompts appear again on the next run —
  useful when a scenario should always start from the not-yet-decided state.
- **Stuck via MCP?** `ft_launch bundleId: com.apple.springboard` attaches non-destructively so
  `ft_snapshot` can read the dialog by ref; `ft_launch` back to the app under test afterward.

### Link
- [index](../index.md)
