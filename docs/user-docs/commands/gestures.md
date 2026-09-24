# gestures (doubleTap, pinchOut, pinchIn, gesture)

Multi-touch gestures: double tap, pinch to zoom out, pinch to zoom in, and a raw multi-finger
gesture builder for anything those three cannot express.

## Functions

| function | description |
|---|---|
| `doubleTap(sel?)` | Double taps. Omitting the selector taps the center of the screen. Writing `tap` twice does not substitute for it — the round trip exceeds the OS's double-tap detection window. |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5, maxGestureSeconds:)` | Spreads two fingers apart = zoom in. `scale` must be greater than 1. `durationSeconds` is capped at 10 seconds by default — pass `maxGestureSeconds:` to allow up to 60 for this one call. |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5, maxGestureSeconds:)` | Pinches two fingers together = zoom out. `scale` must be greater than 0 and less than 1. Same cap as `pinchOut`. |
| `gesture(sel?, maxGestureSeconds:waitSeconds:) { FTFinger(x:y:).move(x:y:durationSeconds:).hold(seconds:) }` | Replays one or more finger paths as a single continuous touch — for a pattern-lock swipe, a long-press that then drags, a two-finger rotate, or anything `pinchOut`/`pinchIn`/`doubleTap`/`swipeBy` cannot express. |

See [swipe](./swipe.md) for `swipeBy(sel?, dxRatio:dyRatio:durationSeconds:)`, the panning
gesture these are usually combined with.

## Example

```swift
doubleTap("#photo")
pinchOut("#map", scale: 2.5)
pinchIn("#map", scale: 0.4)
swipeBy("#map", dxRatio: -0.3, dyRatio: 0.0)   // pan left
```

## `gesture`: a multi-finger path that never lifts

```swift
gesture("#pad_map") {
    FTFinger(x: 0.3, y: 0.35).hold(seconds: 0.3)
        .move(x: 0.6, y: 0.35, durationSeconds: 0.3)
        .move(x: 0.6, y: 0.65, durationSeconds: 0.3)
}
gesture("#pad_map") {                 // two fingers = a hand-built pinch
    FTFinger(x: 0.45, y: 0.5).move(x: 0.2, y: 0.5, durationSeconds: 0.5)
    FTFinger(x: 0.55, y: 0.5).move(x: 0.8, y: 0.5, durationSeconds: 0.5)
}
```

Unlike calling `swipePointToPoint` (or any other gesture command) repeatedly — each call lifts the
finger — every `FTFinger` in a `gesture` block is replayed as **one continuous touch sequence**:
fingers touch down, move/hold in order, and only lift at the end of their own path. Coordinates
are **ratios of the target's frame** (0...1 is inside it; a point outside is fine as long as it's
still on screen), so the same gesture works at any resolution. Omitting the selector targets the
whole screen; loops and branches are allowed inside the block. Limits: 1–5 fingers, up to 625
points per finger, total duration capped at 10 seconds by default (`maxGestureSeconds:` raises it
to 60, same rule as the other gesture commands). An invalid spec (no fingers, an off-screen point,
a non-positive duration, too long a gesture) fails the step without touching the device.

**On iOS this always runs through the XCUITest engine**, even under the default hybrid engine —
the in-app engine has no route for it (it uses the same private pointer-event API as the
coordinate pinch). Use cases: pattern lock, long-press-then-drag without lifting (e.g. reordering
a list), a custom two-finger rotate, gestures needing 3+ fingers, drawing or signing.

## Maps, image viewers, drawing canvases

For a map, image viewer, or drawing surface, operate it with these four commands: `swipeBy` to
pan (diagonal included), `pinchOut`/`pinchIn` to zoom, `doubleTap` to zoom in. Three things to
keep in mind:

- **A pinch is aimed by an area on every engine, and the fingers land at the same spot regardless
  of engine.** A single rule per OS (`FTCore.PinchGesture`, host-side) decides the finger
  coordinates, and every bridge — in-app and XCUITest alike — replays them. On iOS the two fingers
  sit side by side along the region's long side, 0.8 inside its edges; on Android they sit on the
  region's short side, 90% of it apart, centred. XCUITest sends these coordinates through a
  private API; only on an Xcode without that API does it fall back to resolving an element by its
  `accessibilityIdentifier` — and it says so in a note on the step.
- **`pinchOut()` / `pinchIn()` written without a target pinch a small area at the centre of the
  screen**, not the whole screen. **A pinch does not happen when the two fingers land on different
  things**: measured on Apple Maps (2026-09-22), pinching the whole screen put the lower finger on
  the search card, and a zoom out turned into a pan of the map (a zoom in still worked, because
  there the fingers start at the centre and spread out). fleetest therefore picks a spot where both
  fingers stay on the same thing, narrowing the span if it has to, and falls back to the whole
  screen only when no such spot exists.
- **On iOS, only double tap can fail to register, depending on the framework and the engine.**
  The default hybrid engine (Simulator) runs every gesture on every framework. Android has no such
  split — every gesture works everywhere:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter | React Native |
  |---|---|---|---|---|
  | `swipeBy` (diagonal included) | ✅ | ✅ | ✅ | ✅ |
  | `doubleTap` | ✅ | ✅ **hybrid only** | ✅ | △ |
  | `pinchOut` / `pinchIn` | ✅ | ✅ | ✅ | ✅ |
  | `gesture` | ✅ | ✅ | ✅ | ✅ |

  - **"hybrid only"**: works only with the default hybrid engine (Simulator). **With an
    `xcuitest`-only profile or on a physical device, a Compose app does not recognize the double
    tap** (a physical device cannot be injected into, so there is no other way to send it).
  - **"△"**: it arrives, but a screen that detects taps in JavaScript (PanResponder and a clock,
    for example) can miss it intermittently.
  - The MCP `ft_*` tools and Live Control follow the same rules (MCP uses the run's engine when you
    pass a `profile`).
- **Where double tap does not register, check the zoom with `pinchOut` instead.** On a screen where
  double tap means "zoom in" (maps, photos), `pinchOut` produces the same zoom for you to verify.
  Pinch works on every framework, Compose included, with either engine:

  ```swift
  // instead of doubleTap("#map")
  pinchOut("#map")
  select("#zoom_level").textIs("x2")
  ```

  It is not a substitute when double tap does something other than zooming (a "like", for
  example); check that on the Simulator (hybrid) or on Android.
- **The zoom scale you ask for is not always the scale you get.** Two fingers cannot move outside
  the region being pinched, so an extreme `scale` caps out at whatever that region's size allows.
  **Verify that zooming happened rather than the exact scale** — this holds up better across
  apps than asserting a precise value.

### Link
- [index](../index.md)
