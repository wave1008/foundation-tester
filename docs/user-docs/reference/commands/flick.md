# flick

[in Japanese(日本語)](flick_ja.md)

A single fast finger stroke — screen (or `scrollFrame`) based, in one of 8 directions.

## Functions

| function | description |
|---|---|
| `flickCenterToTop(scrollFrame:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickCenterToBottom` / `flickCenterToLeft` / `flickCenterToRight` | Flicks from the center of the screen (or `scrollFrame`) toward that edge. `durationSeconds` is capped at 10 seconds by default — pass `maxGestureSeconds:` to allow up to 60 for this one call. |
| `flickLeftToRight(scrollFrame:startMarginRatio:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickRightToLeft` | Flicks edge to edge, horizontally. `startMarginRatio` defaults to the same value `scrollRight` etc. use (0.2). Same `durationSeconds` cap as above. |
| `flickBottomToTop(scrollFrame:startMarginRatio:durationSeconds: 0.25 maxGestureSeconds: repeat: 1 intervalSeconds: 0.3 settle:)` / `flickTopToBottom` | Flicks edge to edge, vertically. Same `durationSeconds` cap as above. |

**`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

## Example

```swift
flickLeftToRight()                          // one quick horizontal flick, whole screen
flickCenterToTop(scrollFrame: "#carousel")  // flick inside a specific scrollable region
```

## Notes

- `flick` is a **content-agnostic gesture** — unlike `scroll*` (which searches for an element and
  stops once found), `flick` just sends a single fast stroke. Its default `durationSeconds` /
  `intervalSeconds` are shorter than `swipe`'s, matching Shirates' flick timing.
- There is no `scrollableElement` argument — pass the region as a `scrollFrame:` selector
  instead, same as [scroll](./scroll.md).
- There is no `flickAndGo*` family (screen-transition triggers) and no element-anchored
  `flickTo*` / `flickOut*`.
- **`flick` has no notion of "reached the edge."** Chaining several flicks to move faster than
  `scrollToBottom` etc. does not tell you whether you arrived — verify the destination yourself
  after flicking.

### Link
- [index](../../index.md)
