# swipe

Raw finger gestures: a whole-screen swipe, a point-to-point drag, an element-to-element drag, or
a ratio-based drag from an element.

## Functions

| function | description |
|---|---|
| `swipe(.up / .down / .left / .right)` | Swipes the whole screen in the direction of the **finger's movement**. This is the one exception to the "direction is content-based" rule that applies to `scroll*` — see [scroll](./scroll.md). |
| `swipePointToPoint(startX:startY:endX:endY:durationSeconds: 1.5)` | Drags between two points. Coordinates use the same system as the `screen` frame in a snapshot — iOS = pt, Android = px. |
| `swipeElementToElement(開始sel, 終点sel, durationSeconds: 1.5)` | Drags from one element to another (sliders, reordering, drag within a bounded area). Only the start point is healed — the end point is not a self-healing target. |
| `swipeBy(sel?, dxRatio:dyRatio:durationSeconds: 1.5)` | Moves the finger by a **ratio** of the target's size, starting from its center. Both a horizontal and a vertical ratio can be non-zero for a diagonal drag. The ratio's sign is the direction of the finger. Omitting the selector targets the whole screen. |

## Example

```swift
swipe(.up)                                          // whole-screen swipe, finger moves up

swipePointToPoint(startX: 50, startY: 400, endX: 300, endY: 400, durationSeconds: 1.0)

swipeElementToElement("#slider_handle", "#slider_track_end")

swipeBy("#map", dxRatio: -0.3, dyRatio: -0.2, durationSeconds: 0.5)  // pan diagonally
```

## Notes

- **`swipe` is the only command whose direction is the finger's movement**, not content
  movement. Every `scroll*` command is content-based (`.down` = reveal content further down =
  the finger moves up).
- `swipeBy` and `swipeElementToElement` are the building blocks used for maps, image viewers, and
  drawing canvases — see [gestures](./gestures.md) for panning/zooming a map or canvas.

### Link
- [index](../index.md)
