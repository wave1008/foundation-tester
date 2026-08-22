# scroll

Content-based scrolling: search for an element while scrolling, scroll a fixed amount, or scroll
to an edge.

## Functions

| function | description |
|---|---|
| `scrollTo(sel, direction: .down, maxSwipes: 8, containerInference:)` | Scrolls until the element is found (found = success; does not tap it). |
| `scrollDown(repeat: 1)` / `scrollUp` / `scrollRight` / `scrollLeft` | Scrolls one screenful (`repeat:` times to repeat). |
| `scrollToBottom(maxSwipes: 50)` / `scrollToTop` / `scrollToRightEdge` / `scrollToLeftEdge` | Scrolls to the edge — until the screen stops changing. `maxSwipes` is a runaway guard; hitting it leaves a note on the step. |
| `withScrollDown { … }` / `withScrollUp` / `withScrollRight` / `withScrollLeft` | Makes every `tap` / `type` / `clearInput` / `select` / `exist` / `notExist` inside the block search by scrolling (an explicit `scroll:` on a command still wins). **`notExist` changes meaning** inside the block — it fails as soon as the element turns up while scrolling. |
| `withoutScroll { … }` | Cancels an outer `withScroll*` — commands inside resolve against the current screen only. |
| `withoutContainerInference { … }` | Disables the container-inference corrections (below) for every command inside the block. |
| `tapWithScrollDown(sel, maxSwipes:)` etc. (4 directions) | Alias for `tap(sel, scroll: .down)`. |
| `tapWithoutScroll(sel, timeout:)` | Skips scrolling for this one command even inside a `withScroll*` block. |
| `existWithScrollDown(sel, maxSwipes:)` / `existWithScrollUp` | Alias for `exist(sel, scroll: .down)`. |
| `existWithoutScroll(sel, timeout:requireVisible:)` | Asserts existence against the current screen only, even inside a `withScroll*` block. |
| `selectWithScrollDown(sel, maxSwipes:)` etc. (4 directions) | Alias for `select(sel, scroll: .down)`. |
| `selectWithoutScroll(sel, timeout:requireVisible:)` | Resolves against the current screen only, even inside a `withScroll*` block. |

**The `*WithScroll*` aliases only take `maxSwipes:`** (`select` ones also take `requireVisible:`).
If you need `timeout:` or `holdSeconds:` too, use the base command's `scroll:` argument instead:
`tap(sel, scroll: .down, timeout: 2)`. `existWithScrollLeft`/`Right` do not exist for the same
reason — write `exist(sel, scroll: .left)`.

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
| `the screen did not settle (poll limit)` | Waited 600ms after a swipe but the screen was still moving (long inertia, etc.). The swipe itself was still sent. | Usually not. If it appears at the same spot every run, a tap right after could land while the content is still moving — worth investigating. |
| `fell back to XCUITest` | The in-app engine could not run this scroll and fell back (several hundred ms slower per call). | Usually not. If it happens a lot, reconsider the run profile's engine selection. |

## How fast an edge scroll runs depends on the engine

`scrollToBottom` etc. repeat "swipe, then read the tree to see if it stopped moving." How much
one swipe covers, and whether a round trip is even needed, depends on the engine:

| engine | per-swipe movement | cost on long content |
|---|---|---|
| iOS in-app (UIKit/SwiftUI, WebView) | jumps straight to the edge (moves `contentOffset` directly — no gesture, no inertia) | independent of document length |
| Android WebView | jumps the page in one shot via CDP (falls back to a gesture if unavailable) | independent of document length |
| iOS in-app (Compose / Flutter) | one screen per call (the accessibility scroll API has no adjustable step) | proportional to page count |
| iOS xcuitest | a real fling gesture (roughly 1.1 screens) | proportional to page count |
| Android (native) | a real swipe stroke (roughly 1.2 screens) | proportional to page count; default `maxSwipes: 50` may not reach very long documents |

Raise `maxSwipes` for long documents on a real-gesture engine. Chaining several `flick*` calls to
go faster is not a substitute — flick has no notion of having reached the edge; see
[flick](./flick.md).

## Example

```swift
tap("設定", scroll: .down)          // scroll to find the item behind a fold, then tap it
withScrollDown {
    tap("#row_40")                  // searched for even though not written explicitly
    existWithoutScroll("#header")   // a fixed header, checked on the current screen only
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
| whole run (**top-level kill switch**) | environment variable `FT_CONTAINER_INFERENCE=off` — overrides all three below |
| one command | `tap(sel, containerInference: false)` / `scrollTo(sel, containerInference: false)` |
| a block | `withoutContainerInference { … }` (applies to `tap`/`exist`/`select` and every other command inside) |
| the whole run profile | the run profile's `containerInference: false` |

Excluding the environment variable, precedence is: explicit argument > block context > run
profile default.

### Link
- [index](../index.md)
