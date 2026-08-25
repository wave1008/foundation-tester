# irregularHandler

Declares an in-app message (promo card, announcement) that may or may not appear, and closes
it automatically whenever it does.

## Functions

| function | description |
|---|---|
| `irregularHandler(detect, dismiss:, maxDismissals: 10)` | Declares an interruption. Whenever `detect` resolves during any later step (operation or assertion), it is closed automatically — `dismiss` is tapped if given, otherwise `detect` itself is tapped. Typically declared once in `setUp()`. |

## Example

```swift
func setUp() {
    irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
}
```

## Notes

- **Fires during both operation and assertion waits.** Because assertions poll each cycle
  against the current tree, a modal that opens while a scenario is waiting on `exist` /
  `textIs` gets closed too, not just when the scenario is mid-tap.
- **Up to 10 closes per step** by default (`maxDismissals:` to change it) — enough for a modal
  that reopens mid-step. If the same thing is still on screen after two closes, the tool gives
  up and records that it was not fully closed.
- **Conditions close interruptions before answering.** `ifCanSelect` and
  `repeatWhileCanSelect` close a declared interruption first, then judge — otherwise a covered
  target would silently read as "not found" and the scenario would take a wrong branch instead
  of failing loudly. Whether it was dismissed is recorded even when the condition itself does
  not resolve.
- **Does not touch OS system dialogs** (permission prompts, "Open in …?"). Those are drawn by a
  separate process and are outside what `irregularHandler` can see — see
  [iosAlertHandler](./ios_alert_handler.md).
- **Modals in a separate window (iOS)**: some in-app message SDKs draw on a separate `UIWindow`
  rather than the app's key window. The tool still sees these:
  - The modal itself is in the tree (`exist` finds it, `irregularHandler` can close it).
  - **A screen it fully covers drops out of the tree** — `exist` on something underneath fails
    and a tap on it fails as "not found", so a covered screen never reads as a false pass.
  - A modal covering only part of the screen (a top banner, say) leaves the rest of the tree in
    place — the judgment is whether the front window actually receives the touch at that spot,
    not whether the element is visually hidden.
  - Taps, scrolls, and screenshots all reach the frontmost window at that point, not necessarily
    the app's main window.

### The interruption swallowed an interaction

If a declared interruption appears **between** sending an interaction and it taking effect, the
tool cannot tell whether the interaction already landed. It never resends it — resending could
double-fire something that already went through (a submit, a purchase). If the step that closed
the interruption then fails, a note like this is recorded:

```
the interruption appeared during this step — an interaction sent just before it
may have been swallowed by it (nothing was re-sent: repeating it could double-fire)
```

Recovering from this is the scenario's job — check whether the intended state was reached (e.g.
`ifCanSelect`) and repeat the tap if not, but **only for interactions that are safe to repeat**.
A navigation tap is safe; a confirm/submit/pay action is not, since only the scenario's author
knows which is which.

### Link
- [index](../index.md)
