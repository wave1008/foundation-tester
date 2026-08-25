# suppressHandler, useHandler, disableHandler, enableHandler

Lets a scenario operate a modal itself instead of having a declared
[`irregularHandler`](./irregular_handler.md) close it automatically.

## Functions

| function | description |
|---|---|
| `suppressHandler { }` | Runs the block without closing declared interruptions, so the scenario can check or operate the modal itself. Block form — suppression is always restored when the block exits, even on failure. |
| `useHandler { }` | Inside `suppressHandler` (or between `disableHandler()`/`enableHandler()`), restores automatic closing for this block only. |
| `disableHandler()` | Stops closing declared interruptions until `enableHandler()`. Unlike `suppressHandler`, this spans `condition` / `action` / `expectation` blocks. |
| `enableHandler()` | Resumes what `disableHandler()` stopped. |

## Example

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")   // declaration stays in setUp
}

suppressHandler {
    exist("#promo_modal")          // verify it appeared
    tap("#btn_promo_detail")       // operate it yourself
}                                   // automatic closing resumes on exit
```

Crossing a scene's `condition` / `action` / `expectation` boundary needs the imperative form,
since `suppressHandler { }` can only wrap a single block:

```swift
condition {
    disableHandler()
    exist("#promo_modal")       // just confirm it appeared
}.action {
    tap("#btn_promo_detail")    // still suppressed here
}.expectation {
    exist("#detail_screen")
    enableHandler()             // automatic closing resumes from here
}
```

## Notes

- **`suppressHandler { }` is block form**, so a failure inside it still restores automatic
  closing on the way out — use it whenever the whole interaction with the modal fits in one
  block.
- **`disableHandler()` / `enableHandler()` is the only pair that spans `condition` / `action` /
  `expectation`** — reach for it when the scenario needs to check the modal in `condition {}`
  and act on it in `action {}`.
- **`useHandler { }` restores closing for a nested block only**, without ending the outer
  suppression — the outer `suppressHandler` or `disableHandler()` resumes again once the nested
  block exits.
- **Suppressing does not stop the app from showing the interruption** — only from closing it.
  Sending a tap while a modal is up can still be swallowed by it; see
  [irregularHandler](./irregular_handler.md) for how a swallowed interaction is reported.
- If a step fails while suppression is still active, the failure note includes: *"a declared
  interruption was on screen but automatic closing is suppressed here"* — nothing is added when
  the step succeeds.
- **Forgetting to call `enableHandler()` after `disableHandler()` leaves suppression on for the
  rest of the scenario** — after an abort, only `tearDown()` still runs, so any interruption
  during cleanup will not be auto-closed either. Use the block form when this matters.
- OS system dialogs (permission prompts) are not affected by any of these — that is a separate
  mechanism, see [iosAlertHandler](./ios_alert_handler.md). In particular, an alert that a
  scenario is resolving directly (`tap("Allow")`, `ifCanSelect`) is never taken from it either
  way, suppressed or not.

### Link
- [index](../index.md)
