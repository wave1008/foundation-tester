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

- **How a pinch's target is resolved differs by engine.** Android and iOS in-app synthesize the
  two touch points around the center of the specified region. **iOS XCUITest has no
  coordinate-based multi-touch gesture**, so it pinches by resolving an element via its
  `accessibilityIdentifier` instead. **An element without an id, targeted through XCUITest, falls
  back to pinching the whole screen** — this is left as a note on the step.
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
