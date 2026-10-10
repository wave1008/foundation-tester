# wait, waitForDisplay, waitForClose, waitForSettle

[in Japanese(日本語)](wait_ja.md)

Fixed pauses, explicit waits for an element to appear or disappear, and an explicit wait for the screen to stop moving.

## Functions

| function | description |
|---|---|
| `wait(seconds)` | Fixed sleep. Decimal seconds allowed. |
| `waitForDisplay(sel, waitSeconds: 15)` | Waits until the element is displayed (does not scroll). Returns an `FTElement`, chainable the same way `exist` is. Fails the scenario if it never appears. |
| `waitForClose(sel, waitSeconds: 15)` | Waits until the element disappears (does not scroll). `sel` is required — there is no "reuse the previous selector" shorthand. |
| `waitForSettle(sel?, quietSeconds:, throwsException: true, waitSeconds: 15)` | Waits until the pixels of the screen (or of the element's frame, when `sel` is given) have not changed at all for `quietSeconds`, then until the accessibility tree has caught up, and returns `true`. Returns a `Bool` (`@discardableResult`, so it can be used in `if`). Details below. |

## Example

```swift
tap("#submit")
waitForDisplay("#confirmation_toast", waitSeconds: 10)
waitForClose("#loading_spinner", waitSeconds: 15)
wait(0.5)     // only for settling that no selector can express (e.g. an in-flight animation)

flickCenterToBottom()
waitForSettle()                    // let the scroll inertia stop completely
findImage("[Camera Icon]").tap()   // now the image is read from a still screen
```

## Notes

- **Element appearance is already implicit** — operations retry resolution (about 0.7 seconds without `waitSeconds:`) and assertions poll
  until their timeout, so putting `wait()` before an `exist()` is redundant. If a wait is not
  long enough, raise the command's `waitSeconds:` (decimal allowed) instead of adding a fixed
  `wait()`.
- **`wait()` is a last resort** for settling that has no selector to poll on, such as a
  coordinate shifting mid-animation. It is not a substitute for `waitForDisplay` /
  `waitForClose`. To wait for the screen to stop moving, use `waitForSettle` instead of a fixed
  `wait()`.
- **`waitForDisplay` judges visibility the same way `exist` does** (the name matches its
  meaning) — there is no `requireVisible: false` escape hatch on it. If you want to skip the
  occlusion check while still waiting, use `exist(sel, requireVisible: false, waitSeconds: 15)`
  instead.
- `waitForDisplay` / `waitForClose` never scroll to find the element; if it might be off-screen,
  scroll first or use `scrollTo`.

## waitForSettle

```swift
@discardableResult
waitForSettle(_ selector: String? = nil, quietSeconds: Double? = nil,
              throwsException: Bool = true, waitSeconds: Double? = nil) -> Bool
```

Waits until the screen has stopped moving. **It waits only when you write it** — ordinary operations
(`tap`, `swipe`, `scroll*`, …) do not wait for the pixels to be still. Write it right before a step
that reads the picture:

- an image check (`findImage` / `existImage` / `imageIs`) or a text visual verification that uses OCR
- an operation that depends on exact pixels
- a screenshot for the report

It matters most right after a scroll or a flick, when inertia may still be moving the content.

### What it waits for

Two stages, both inside the limit `waitSeconds`:

1. **Image** — the pixels of the compared region have not changed at all for `quietSeconds`.
2. **Tree** — once the picture is still, the accessibility tree has caught up: two consecutive snapshots of the
   elements in the region are identical. (The tree can lag behind the picture, so the next step could
   otherwise resolve against an old tree.)

It returns `true` when both stages finish in time.

### Arguments

| argument | meaning |
|---|---|
| `selector` | Omitted = the whole screen. With a selector, the element's frame is the compared region. Use it to leave out things that never stop (spinners, shimmering skeleton placeholders) by passing an element that does not contain them. If the element cannot be found, the step **always fails** (see `throwsException`). |
| `quietSeconds` | How long the screen must stay unchanged to count as still — the criterion. Range 0.1–5 seconds. The default depends on the app's UI framework: **0.8 s** on iOS Compose Multiplatform (and when the framework cannot be determined), **0.5 s** on other iOS frameworks and on Android. These are the longest gap between redraws measured at the end of scroll inertia (a 650 ms 1-pixel crawl on Compose Multiplatform, 368 ms on SwiftUI, 385 ms on Android under load) with about 20% margin. |
| `waitSeconds` | The upper limit for the whole wait (finding the `selector` element + image + tree). If the element cannot be found, the step keeps looking until this limit and then fails. Default 15 seconds, like `waitForDisplay` / `waitForClose` / `appIs`. Range 0–60 seconds. |
| `throwsException` | Default `true`. When the screen (or the tree) does not settle within `waitSeconds`: `true` = the step fails and the scenario aborts; `false` = the step passes with the note `settle-not-reached` and the function returns `false`. |

### Notes

- **The compared region is always trimmed by 10% on each edge.** Scroll bars and indicators that fade out, the
  status bar, and the home indicator keep changing after the content has stopped. This applies to both the
  whole screen and an element's frame.
- **`throwsException: false` covers only the timeout.** If the `selector` element cannot be found, the step
  fails whichever value you pass. No argument in fleetest lets a missing element pass; this is the one documented
  exception, and it is limited to the timeout of this command.
- **Failure messages state facts.** In the image stage: `the screen kept changing for N s (last change at x, y, w×h)`.
  In the tree stage: `the screen was still but the accessibility tree kept changing for N s (changing: …)`. If finding
  the element used up most of the limit and less than `quietSeconds` was left, the message is
  `only N s of waitSeconds was left after finding the element, …` (there was no time left to confirm stillness). If
  something that never stops keeps failing it, pass a `selector` that excludes it, or adjust `quietSeconds` /
  `waitSeconds`.
- **The judgement happens inside the bridge; the images never go to the host.**
  - On iOS, the pixels are always captured by the XCUITest runner, even in the default `hybrid` engine. The
    in-app engine sees only the app's own drawing (no keyboard, system alerts or other processes), and capturing
    in-process would block the app's main thread. The tree stage uses the driver that resolves the next step (in
    `hybrid`: the in-app tree). A device configured with `engine: "inapp"` only (no XCUITest runner) fails with a
    message to switch to `hybrid` or `xcuitest`.
  - On Android, the bridge running in the instrumentation captures the pixels.
- `ft_batch` (MCP) accepts the `waitForSettle` key with the same arguments.

### Link
- [index](../../index.md)
