# wait, waitForDisplay, waitForClose

Fixed pauses and explicit waits for an element to appear or disappear.

## Functions

| function | description |
|---|---|
| `wait(seconds)` | Fixed sleep. Decimal seconds allowed. |
| `waitForDisplay(sel, waitSeconds: 15)` | Waits until the element is displayed (does not scroll). Returns an `FTElement`, chainable the same way `exist` is. Fails the scenario if it never appears. |
| `waitForClose(sel, waitSeconds: 15)` | Waits until the element disappears (does not scroll). `sel` is required — there is no "reuse the previous selector" shorthand. |

## Example

```swift
tap("#submit")
waitForDisplay("#confirmation_toast", waitSeconds: 10)
waitForClose("#loading_spinner", waitSeconds: 15)
wait(0.5)     // only for settling that no selector can express (e.g. an in-flight animation)
```

## Notes

- **Element appearance is already implicit** — operations retry resolution and assertions poll
  until their timeout, so putting `wait()` before an `exist()` is redundant. If a wait is not
  long enough, raise the command's `timeout:` (decimal allowed) instead of adding a fixed
  `wait()`.
- **`wait()` is a last resort** for settling that has no selector to poll on, such as a
  coordinate shifting mid-animation. It is not a substitute for `waitForDisplay` /
  `waitForClose`.
- **`waitForDisplay` judges visibility the same way `exist` does** (the name matches its
  meaning) — there is no `requireVisible: false` escape hatch on it. If you want to skip the
  occlusion check while still waiting, use `exist(sel, requireVisible: false, timeout: 15)`
  instead.
- `waitForDisplay` / `waitForClose` never scroll to find the element; if it might be off-screen,
  scroll first or use `scrollTo`.

### Link
- [index](../index.md)
