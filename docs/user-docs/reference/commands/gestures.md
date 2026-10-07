# Gestures for maps and canvases (doubleTap, pinchIn, pinchOut, gesture, hold)

[in Japanese(日本語)](gestures_ja.md)

Multi-touch gestures: double tap, pinch to zoom out, pinch to zoom in, and a raw multi-finger
gesture builder for anything those three cannot express.

## Functions

| function | description |
|---|---|
| `doubleTap(sel?)` | Double taps. Omitting the selector taps the center of the screen. Writing `tap` twice does not substitute for it — the round trip exceeds the OS's double-tap detection window. |
| `pinchOut(sel?, scale: 2.0, durationSeconds: 0.5, maxGestureSeconds:)` | Spreads two fingers apart = zoom in. `scale` must be greater than 1. `durationSeconds` is capped at 10 seconds by default — pass `maxGestureSeconds:` to allow up to 60 for this one call. |
| `pinchIn(sel?, scale: 0.5, durationSeconds: 0.5, maxGestureSeconds:)` | Pinches two fingers together = zoom out. `scale` must be greater than 0 and less than 1. Same cap as `pinchOut`. |
| `gesture(sel?, maxGestureSeconds:waitSeconds:) { FTFinger(x:y:).move(x:y:durationSeconds:).hold(seconds:) }` | Replays one or more finger paths as a single continuous touch — for a pattern-lock swipe, a long-press that then drags, a two-finger rotate, or anything `pinchOut`/`pinchIn`/`doubleTap`/`swipeBy` cannot express. |
| `hold(sel, holdSeconds: 3, maxGestureSeconds:, waitSeconds:, scroll:, maxSwipes:) { … }` | Runs the block while the finger stays down (for checking a component that only shows while pressed). `holdSeconds` defaults to 3 seconds. See the `hold` section below. |

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
to 60, same rule as the other gesture commands). To put a finger down late, use `FTFinger(x:y:startSeconds:)` (`startSeconds` is the delay in seconds from
the start of the gesture until that finger touches down; default 0 — meant for fingers after the first.
It must be a finite value of 0 or more). An invalid spec (no fingers, an off-screen point,
a non-positive duration, too long a gesture) fails the step without touching the device.

**On iOS this command always runs through XCUITest, even under the default hybrid engine.** Use cases: pattern lock,
long-press-then-drag without lifting (e.g. reordering a list), a custom two-finger rotate,
gestures needing 3+ fingers, drawing or signing.

## `hold`: verifying something that only shows while pressed

`tap(sel, holdSeconds:)` presses and releases within one step, so a component that only appears
while a finger is down (a tooltip, for example) is already gone by the time anything runs after
it. `hold` keeps the finger down for the whole block instead:

```swift
hold("#btn_tooltip_anchor", holdSeconds: 3) {
    select("#txt_tooltip").textIs("This is a tooltip")
}
```

The finger lifts by itself `holdSeconds` after it went down; the block runs while it is still down. If the block finishes
before `holdSeconds` is up, `hold` waits for the release before returning. If the block
takes longer than `holdSeconds`, the finger is already up for the rest of it — this is noted but
not treated as a failure. Holds cannot be nested (start a second one only after the first one's
block has finished), and if the target cannot be resolved the block does not run at all. **On iOS
with the default hybrid engine, the press always runs through XCUITest** (same as
`tap`'s long press).

## Maps, image viewers, drawing canvases

For a map, image viewer, or drawing surface, operate it with these four commands: `swipeBy` to
pan (diagonal included), `pinchOut`/`pinchIn` to zoom, `doubleTap` to zoom in. Three things to
keep in mind:

- **The fingers of a pinch land at the same spot regardless of engine.** On iOS the two fingers
  sit side by side along the region's long side, 0.8 inside its edges; on Android they sit on the
  region's short side, 90% of it apart, centred. On an older Xcode a different method is used
  instead, and a note on the step says so.
- **`pinchOut()` / `pinchIn()` written without a target pinch a small area at the centre of the
  screen**, not the whole screen. **A pinch does not happen when the two fingers land on different
  things**: pinching the whole screen can put one finger on another component and turn the pinch
  into a pan of the map. fleetest therefore picks a spot where both fingers land on the same
  element, narrowing the span if it has to, and pinches the whole screen only when no such spot
  exists.
- **On iOS, only double tap can fail to register, depending on the framework and the engine.**
  The default hybrid engine (Simulator) runs every gesture on every framework. Android has no such
  split — every gesture works everywhere:

  | iOS | SwiftUI / UIKit | Compose Multiplatform | Flutter | React Native |
  |---|---|---|---|---|
  | `swipeBy` (diagonal included) | ✅ | ✅ | ✅ | — |
  | `doubleTap` | ✅ | ✅ **hybrid only** | ✅ | △ |
  | `pinchOut` / `pinchIn` | ✅ | ✅ | ✅ | ✅ |
  | `gesture` | ✅ | ✅ | ✅ | ✅ |

  - **"hybrid only"**: works only with the default hybrid engine (Simulator). **With an
    `xcuitest`-only profile or on a physical device, a Compose app does not recognize the double
    tap** (a physical device cannot be injected into, so there is no other way to send it).
  - **"△"**: it arrives, but a screen that detects taps in JavaScript (PanResponder and a clock,
    for example) can miss it intermittently.
  - **"—"** means not verified.
  - For using this from MCP, see [MCP server](../tools/mcp_server.md).
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
- [index](../../index.md)
