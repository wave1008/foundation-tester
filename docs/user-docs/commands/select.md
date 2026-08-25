# select

Grabs an element without touching the device, for reading values or chaining assertions.

## Functions

| function | description |
|---|---|
| `select(sel, timeout:requireVisible:scroll:maxSwipes:)` | Grabs an element. Unlike `exist`, this is **not an assertion** — it does not appear as a verification step in the report. Used as the starting point for reading a value (`.text` / `.value` / `.id`) or for chaining an assertion. If the element cannot be grabbed, it does not fail — it returns an empty element instead, so callers branch on `.isEmpty` / `.isNotEmpty`. Use `exist` when you need to assert the element is there. `requireVisible: false` skips the visibility check entirely. |
| `selectWithScrollDown(sel, requireVisible:maxSwipes:)` / `selectWithScrollUp` / `selectWithScrollRight` / `selectWithScrollLeft` | Shorthand for `select(sel, scroll: .down)` and so on. |
| `selectWithoutScroll(sel, timeout:requireVisible:)` | Grabs from the current screen only, even inside a `withScrollDown { }` block. |
| `lastElement` | The **most recently grabbed element** (no arguments). Any command that resolves a single element — `select` / `exist` / `tap` / `type` / `waitForDisplay` / text and value assertions — replaces it when it succeeds. It holds the value at the moment it was grabbed; scrolling or tapping afterwards does not refresh it. |

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
- [index](../index.md)
