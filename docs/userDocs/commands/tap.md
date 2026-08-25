# tap

Taps an element, or raw coordinates, on the screen.

## Functions

| function | description |
|---|---|
| `tap(sel, holdSeconds: 0, timeout:scroll:maxSwipes:containerInference:)` | Taps the first element matching the selector. `holdSeconds` greater than 0 makes it a long press (default 0 = normal tap). Waits for the target to become enabled before tapping (see Notes). |
| `tap(x: Int, y: Int, holdSeconds: 0)` | Taps raw coordinates. Coordinates use the same system as the `screen` frame in a snapshot — iOS = pt, Android = px (not dp). Prefer a selector whenever one is available. |
| `tapWithScrollDown(sel, maxSwipes:)` / `tapWithScrollUp` / `tapWithScrollRight` / `tapWithScrollLeft` | Shorthand for `tap(sel, scroll: .down)` and so on — scrolls in that direction while searching for the element. See [scroll](./scroll.md). |
| `tapWithoutScroll(sel, timeout:)` | Taps without scrolling, even inside a `withScrollDown { }` block. |
| `tapAppIcon(name?)` | Taps the app icon on the home screen. Name defaults to the app profile's `appName` when omitted. |

## Example

```swift
tap("#login_btn||Log In")
tap("Settings", scroll: .down)         // searches while scrolling down
tap("#row_03", holdSeconds: 1)         // long press
tap(x: 120, y: 640)                    // only when no selector is available
```

## Notes

- **`tap` waits for the target to become enabled before tapping.** A screen can render an
  element before it is actually interactive (a form still loading, a button disabled until
  validation passes). `tap` retries resolution until the element is `enabled`, up to the
  step's `timeout:` (default about 5 seconds). If it never becomes enabled, `tap` still taps
  it — a scenario that deliberately taps a disabled element to assert "nothing happens" keeps
  working. Waiting is skipped when the selector explicitly pins the state, e.g.
  `#btn&&enabled=false`, or when `timeout: 0` is given.
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
- [index](../index.md)
