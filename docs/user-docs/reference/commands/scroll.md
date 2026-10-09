# scroll (scrollTo, scrollDown, withScrollDown, scrollFrame, ...)

[in Japanese(日本語)](scroll_ja.md)

Content-based scrolling: search for an element while scrolling, scroll a fixed amount, or scroll
to an edge.

## Functions

| function | description |
|---|---|
| `scrollTo(sel, direction: .down, containerInference:, settle:, maxSwipes: 8)` | Scrolls until the element is found (found = success; does not tap it). |
| `scrollDown(repeat: 1, settle:)` / `scrollUp` / `scrollRight` / `scrollLeft` | Scrolls one screenful (`repeat:` times to repeat). |
| `scrollToBottom(settle:, maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | Scrolls to the edge — until the screen stops changing. `maxSwipes` is a runaway guard; hitting it leaves a note on the step. |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | Makes every `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` / `findImage` / `existImage` / `hold` inside the block search by scrolling (an explicit `scroll:` on a command still wins). **`notExist` changes meaning** inside the block — it fails as soon as the element turns up while scrolling. |
| `withoutScroll { … }` | Cancels an outer `withScroll*` — commands inside resolve against the current screen only. |
| `withoutContainerInference { … }` | Disables the container-inference corrections (below) for every command inside the block. |
| `scroll: .noScroll` (an argument of `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` / `findImage` / `existImage` / `hold`) | Skips scrolling for this one command even inside a `withScroll*` block (it resolves against the current screen only). Leaving the argument out follows the direction of the block. |

**`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

**Scrolling is specified only through each command's `scroll:` argument.** A direction (`.down` / `.up` / `.right` / `.left`)
searches while scrolling that way, and `.noScroll` never scrolls, even inside a `withScroll*` block. Leaving it out follows
the direction of the enclosing block (outside a block: the current screen only). There are no function-name aliases such as
`tapWithScrollDown` or `existWithoutScroll` (writing one gives a compile error that shows the `scroll:` form).

## The scrollable region: `scrollFrame:`

`scrollFrame:` (also `startMarginRatio:` / `endMarginRatio:`) is an argument on `scroll*` /
`scrollToBottom` etc. / `scrollTo`, and `withScroll*` takes `scrollFrame:` alone. It names, with a
selector, the region that should actually be scrolled — needed when a screen has more than one
scrollable area (a fixed header plus a scrollable list, for example):

```swift
scrollTo("#row_40", scrollFrame: "#list_rows")
```

- **Omitting it scrolls the whole screen**, centered, and margin ratios are ignored.
- `withScrollDown(scrollFrame: "#list") { }` passes the region down to every search inside the
  block.
- **If the region resolves but nothing in it actually moves**, the swipe is still sent but a note
  is left on the step (`the specified scrollFrame is not scrollable`, or
  `resolved but leaves nothing to move` if the margins leave no room).
- **If the region does not resolve to anything on screen, the command fails without sending a
  single swipe** — this applies to `scrollTo`'s search, `scroll*` / `scrollTo*Edge`, `flick*`, and
  anything inside `withScroll*`. `select`-family commands are the one exception: they still
  return an empty element per their own contract rather than failing.

## Notes left on the report

These are observations, not failures:

| note | meaning | worth checking? |
|---|---|---|
| `stopped at the limit of N (may not have reached the edge yet)` | Stopped at `maxSwipes` — not necessarily the actual edge | **Yes.** Raise `maxSwipes`, or check whether the screen even has an edge to reach. |
| `the screen did not settle (poll limit)` | The screen was still moving after a swipe (long inertia, etc.). The swipe itself was still sent. | Usually not. If it appears at the same spot every run, a tap right after could land while the content is still moving — worth investigating. |
| `fell back to XCUITest` | The in-app engine could not run this scroll, so XCUITest did it. | Usually not. If it happens a lot, reconsider the run profile's engine selection. |

## How fast an edge scroll runs

`scrollToBottom` etc. repeat "scroll once, then check whether the screen stopped moving." On Android, and on iOS with the
XCUITest engine or Compose / Flutter, one step covers about one page, so raise `maxSwipes` for long screens (the default
`maxSwipes: 50` may not reach very long documents). iOS UIKit / SwiftUI, WebView, and the Android WebView jump straight to
the edge, so they do not depend on document length. Chaining several `flick*` calls to go faster is not a substitute —
flick has no notion of having reached the edge; see [flick](./flick.md).

## Example

```swift
tap("Settings", scroll: .down)      // scroll to find the item behind a fold, then tap it
withScrollDown {
    tap("#row_40")                  // searched for even though not written explicitly
    exist("#header", scroll: .noScroll)   // a fixed header, checked on the current screen only
}
```

## Container-inference corrections

`tap`/`scrollTo` etc. apply a set of corrections that rely on inferring the scroll container —
clipping detection, re-grabbing a stale element, a rescue drag, coordinate correction for a
partially visible element, and discarding a broken coordinate candidate. These are on by default;
turn them off only when they misfire on an unusual screen layout (a custom scroll container
implementation, for example). Three scopes to choose from:

| scope | how |
|---|---|
| whole run | environment variable `FT_CONTAINER_INFERENCE=off` (only to isolate a problem) — overrides all three below |
| one command | `tap(sel, containerInference: false)` / `scrollTo(sel, containerInference: false)` |
| a block | `withoutContainerInference { … }` (applies to `tap`/`exist`/`select` and every other command inside) |
| the whole run profile | the run profile's `containerInference: false` |

Excluding the environment variable, precedence is: explicit argument > block context > run
profile default.

### Link
- [index](../../index.md)
