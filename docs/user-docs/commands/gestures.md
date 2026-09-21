# gestures (doubleTap, pinchOut, pinchIn)

Multi-touch gestures: double tap, pinch to zoom out, pinch to zoom in.

## Functions

| function | description |
|---|---|
| `doubleTap(sel?)` | Double taps. Omitting the selector taps the center of the screen. Writing `tap` twice does not substitute for it — the round trip exceeds the OS's double-tap detection window. |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5)` | Spreads two fingers apart = zoom in. `scale` must be greater than 1. |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5)` | Pinches two fingers together = zoom out. `scale` must be greater than 0 and less than 1. |

See [swipe](./swipe.md) for `swipeBy(sel?, dxRatio:dyRatio:durationSeconds:)`, the panning
gesture these are usually combined with.

## Example

```swift
doubleTap("#photo")
pinchOut("#map", scale: 2.5)
pinchIn("#map", scale: 0.4)
swipeBy("#map", dxRatio: -0.3, dyRatio: 0.0)   // pan left
```

## Maps, image viewers, drawing canvases

For a map, image viewer, or drawing surface, operate it with these four commands: `swipeBy` to
pan (diagonal included), `pinchOut`/`pinchIn` to zoom, `doubleTap` to zoom in. Three things to
keep in mind:

- **A pinch is aimed by an area on every engine.** Android and iOS in-app synthesize the two touch
  points around the center of the given region; iOS XCUITest places them at the two opposite ends
  of it. Only when the area cannot be used does XCUITest fall back to resolving an element by its
  `accessibilityIdentifier` — and it says so in a note on the step.
- **`pinchOut()` / `pinchIn()` written without a target pinch a small area at the centre of the
  screen**, not the whole screen. **A pinch does not happen when the two fingers land on different
  things**: measured on Apple Maps (2026-09-22), pinching the whole screen put the lower finger on
  the search card, and a zoom out turned into a pan of the map (a zoom in still worked, because
  there the fingers start at the centre and spread out). fleetest therefore picks a spot where both
  fingers stay on the same thing, narrowing the span if it has to, and falls back to the whole
  screen only when no such spot exists.
- **On iOS, whether a gesture works depends on the engine**, for some gestures. The default
  hybrid engine works across every framework (the host picks the engine automatically). Android
  has no such split — every gesture works everywhere:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter |
  |---|---|---|---|
  | `swipeBy` (diagonal included) | ✅ | ✅ | ✅ |
  | `doubleTap` | ✅ XCUITest | ✅ **in-app only** | ✅ |
  | `pinchOut` / `pinchIn` | ✅ XCUITest | ✅ | ✅ **in-app only** |

  "in-app only" means it does not work with a standalone `xcuitest` profile or on a physical
  device (physical devices cannot be injected, so XCUITest is the only path). The MCP `ft_*`
  tools follow the same engine when a `profile` is passed.
- **The zoom scale you ask for is not always the scale you get.** Two fingers cannot move outside
  the region being pinched, so an extreme `scale` caps out at whatever that region's size allows.
  **Verify that zooming happened rather than the exact scale** — this holds up better across
  apps than asserting a precise value.

### Link
- [index](../index.md)
