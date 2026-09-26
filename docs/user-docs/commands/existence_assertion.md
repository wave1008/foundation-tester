# exist, notExist, countIs

Checks whether elements matched by a selector exist, are gone, or number a given count.

## Functions

| function | description |
|---|---|
| `exist(selector, requireVisible:, waitSeconds:, scroll:, maxSwipes:)` | Asserts existence and returns the matched element, so text/value/id checks can chain onto it. On a run with `textVisualCheck: true` in the run profile, also confirms the element is actually visible. |
| `notExist(selector, waitSeconds:, scroll:, maxSwipes:)` | Waits until the element is gone (already absent succeeds immediately). With `scroll:`, scrolls in that direction while searching, and finding the element fails the check; without a match while scrolling, falls back to waiting for disappearance on the current viewport. |
| `countIs(selector, count, waitSeconds:)` | Asserts the number of matching candidates in the tree. Visibility is not considered. `\|\|` counts the union (duplicates counted once). When counting by label, narrow by type first, e.g. `.button&&Add` — a button and its inner label are separate elements and both would match a bare label. |
| `exist(selector, scroll: .noScroll)` | Checks existence on the current screen even inside a `withScrollDown` / `withScrollUp` / `withScrollRight` / `withScrollLeft` block. |

`waitForDisplay` / `waitForClose` wait for an element to appear or disappear without scrolling —
see [wait](./wait.md).

## Example

```swift
expectation {
    exist("#welcome_text||Welcome")
    notExist("#loading_spinner")
    countIs("#row||", 5)
}
```

## Notes

- `exist`'s return value chains into text/value/id checks. See [Text Assertion](./text_assertion.md),
  [Value Assertion](./value_assertion.md), [idIs](./id_assertion.md).
- `exist` / `notExist` / `countIs` always take a selector — they are the commands that resolve
  more than one element, so there is no implicit form that operates on the last grabbed element.
- The "actually visible" check compares the text drawn on screen with the expected text. When
  **only the beginning is drawn** (the same holds for text and value assertions):
  - an ellipsis (`…`) is drawn at the end → green, as truncation the app intended; the step gets
    the note `text-ellipsized`
  - no ellipsis, and more than half of the expected text is drawn → green; the step gets the note
    `text-partially-hidden` (part of the text is hidden)
  - no ellipsis, and half or less is drawn → failed (`most of the text is hidden`). For a screen
    that hides most of a text on purpose, use `requireVisible: false`
  - For examples with images, see [How text visual verification decides](../testclass/text_visual_check.md)

### Link
- [index](../index.md)
