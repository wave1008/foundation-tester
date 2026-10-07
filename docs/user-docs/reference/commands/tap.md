# tap

Taps an element, or raw coordinates, on the screen.

## Functions

| function | description |
|---|---|
| `tap(sel, holdSeconds: 0, maxGestureSeconds:containerInference:linkText:waitSeconds:scroll:maxSwipes:)` | Taps the first element matching the selector. `holdSeconds` greater than 0 makes it a long press (default 0 = normal tap, capped at 10 seconds by default — pass `maxGestureSeconds:` to allow up to 60 for this one call). Waits for the target to become enabled before tapping (see Notes). Returns the tapped element, so assertions chain directly: `tap("#btn_ok").textIs("OK")`. |
| `tap(sel, linkText: "text")` | Taps the place where `linkText` is drawn **inside** the element the selector resolves to — for an inline link in a paragraph, which the accessibility tree does not expose as a node on Compose Multiplatform, Android Views (`ClickableSpan`) and SwiftUI (`AttributedString` links). Located first from the tree (a descendant whose label or value equals `linkText`, as Flutter and React Native expose links), then by OCR on the element's pixels. If neither finds it the step fails and lists what OCR read — it never falls back to the element's centre. The step note records which way located it (`tree` / `ocr`). A link wrapped across two lines is not found by OCR. Without `linkText:` nothing changes. |
| `tap(x: Double, y: Double, holdSeconds: 0, maxGestureSeconds:)` | Taps raw coordinates. Coordinates use the same system as the `screen` frame in a snapshot — iOS = pt, Android = px (not dp). Prefer a selector whenever one is available. On iOS with the in-app engine, a point off the screen or on the software keyboard fails (the in-app engine cannot press keys — close the keyboard with `pressEnter` first), and an element clipped out of its scroll container is not activated even if its frame contains the point. |
| `tap(sel, scroll: .noScroll)` | Taps without scrolling, even inside a `withScrollDown { }` block. |
| `tapAppIcon(name?)` | Taps the app icon on the home screen. Name defaults to the app profile's `appName` when omitted. |

## Example

```swift
tap("#login_btn||Log In")
tap("Settings", scroll: .down)         // searches while scrolling down
tap("#row_03", holdSeconds: 1)         // long press
tap("#txt_terms", linkText: "Terms of Service")   // a link inside a paragraph
tap(x: 120, y: 640)                    // only when no selector is available
```

## Notes

- **`tap` waits for the target to become enabled before tapping.** A screen can render an
  element before it is actually interactive (a form still loading, a button disabled until
  validation passes). `tap` retries resolution until the element is `enabled`, up to the
  step's `waitSeconds:` (5 seconds by default). If it never becomes enabled, `tap` still taps
  it — a scenario that deliberately taps a disabled element to assert "nothing happens" keeps
  working. Waiting is skipped when the selector explicitly pins the state, e.g.
  `#btn&&enabled=false`, or when `waitSeconds: 0` is given.
- **Waiting for the element to appear is short**: without `waitSeconds:`, resolution is retried for only about
  0.7 seconds until the element is found (once found, `tap` waits up to 5 seconds for it to become enabled, as above).
  For an element that appears late after a screen transition, pass `tap("#btn", waitSeconds: 5)` or wait first with
  `waitForDisplay("#btn")`. Other operations such as `type` behave the same.
- **Traditional form**: `tap("#field")` followed by `type("some text")` also works. On Android,
  when `#id` resolves to the input's wrapping container rather than the field itself, focus can
  fail to land in the field; `type` recovers by locating the single input inside the tapped
  container. See [type](./type.md).
- Coordinate taps: use them only when the app exposes nothing selectable at that spot.

  | Use case | Guidance |
  |---|---|
  | Writing a scenario (kept long-term) | Prefer a selector. Coordinates are a last resort — they hit whatever is there once the layout moves. |
  | Ad-hoc exploration | A selector is still preferred, but coordinates are fine if they resolve faster. |

### Link
- [index](../../index.md)
