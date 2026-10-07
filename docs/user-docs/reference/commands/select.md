# select, lastElement

[in Japanese(日本語)](select_ja.md)

Grabs an element without touching the device, for reading values or chaining assertions.

## Functions

| function | description |
|---|---|
| `select(sel, requireVisible:waitSeconds:scroll:maxSwipes:)` | Grabs an element. Unlike `exist`, this is **not an assertion** — it does not appear as a verification step in the report. Used as the starting point for reading a value (`.text` / `.value` / `.id`) or for chaining an assertion. If the element cannot be grabbed, it does not fail — it returns an empty element instead, so callers branch on `.isEmpty` / `.isNotEmpty`. Use `exist` when you need to assert the element is there. `requireVisible: false` skips the visibility check entirely. |
| `select(sel, scroll: .noScroll)` | Grabs from the current screen only, even inside a `withScrollDown { }` block. |
| `select(sel).tap(holdSeconds:maxGestureSeconds:)` | Taps the grabbed element. It resolves the grabbed selector again, so it behaves like `tap(sel)`. An element grabbed by `findImage` / `findImages` is tapped at the center of the found frame, by coordinates (an image element that was not found fails). |
| `select(sel).type(text, replace:waitSeconds:)` | Types into the grabbed element. It resolves the grabbed selector again, so it behaves like `type(sel, text)`. It fails on an element that was not found. Elements grabbed by `findImage` / `findImages` cannot be typed into (call `.tap()` first, then `type(text)`). To just type, `type(sel, text)` is enough. |
| `lastElement` | The **most recently grabbed element** (no arguments). Any command that resolves a single element — `select` / `exist` / `tap` / `type` / `waitForDisplay` / text and value assertions — replaces it when it succeeds. It holds the value at the moment it was grabbed; scrolling or tapping afterwards does not refresh it. |

Every command accepts a typed selector `Sel` in place of a selector string ([typed selector](../selector/typed_selector.md)).

## Example

```swift
select("#btn_ok").textIs("OK")

let e = select("#txt_total")
if e.isNotEmpty {
    // element was found
}
```

Reading a value out of a grabbed element (`.text`, `.value`, `.id`) is covered in
[reading values](./reading_values.md).

## Notes

- `select` never fails a scenario by itself — a missing element becomes an empty element, not a
  thrown error. Only the commands you chain onto it (`.textIs(...)`, etc.) can fail the step.
- `lastElement` is empty at the start of each `scene`, is overwritten with an empty element when
  a command fails to grab, and is empty (with a warning) if nothing has been grabbed yet.

### Link
- [index](../../index.md)
