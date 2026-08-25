# exist, notExist, countIs

Checks whether elements matched by a selector exist, are gone, or number a given count.

## Functions

| function | description |
|---|---|
| `exist(selector, timeout:, requireVisible:, scroll:, maxSwipes:)` | Asserts existence and returns the matched element, so text/value/id checks can chain onto it. On a run with `falsePositiveCheck: true` in the run profile, also confirms the element is actually visible. |
| `notExist(selector, timeout:, scroll:, maxSwipes:)` | Waits until the element is gone (already absent succeeds immediately). With `scroll:`, scrolls in that direction while searching, and finding the element fails the check; without a match while scrolling, falls back to waiting for disappearance on the current viewport. |
| `countIs(selector, count, timeout:)` | Asserts the number of matching candidates in the tree. Visibility is not considered. `\|\|` counts the union (duplicates counted once). When counting by label, narrow by type first, e.g. `.button&&Add` — a button and its inner label are separate elements and both would match a bare label. |
| `existWithScrollDown(selector, maxSwipes:)` / `existWithScrollUp(selector, maxSwipes:)` | Alias of `exist(selector, scroll: .down)` / `exist(selector, scroll: .up)`. Takes only `maxSwipes`. There is no left/right alias. |
| `existWithoutScroll(selector, timeout:, requireVisible:)` | Checks existence on the current screen even inside a `withScrollDown` / `withScrollUp` / `withScrollRight` / `withScrollLeft` block. |

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

### Link
- [index](../index.md)
