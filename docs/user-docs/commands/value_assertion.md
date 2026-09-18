# Value Assertion

Checks on an element's value (e.g. the content of a text field), as opposed to its label. Same
shape as [Text Assertion](./text_assertion.md).

**The target is always "the element grabbed last" — selectors are not passed to these
commands.** First grab the element with `select` (or `exist` / `tap` / etc.), then verify it:

```swift
select("#email").valueIs("test@example.com")             // chain onto the return value
select("#email"); lastElement.valueIs("test@example.com") // explicit lastElement
select("#email"); valueIs("test@example.com")             // implicit (the last grabbed element)
```

Arguments are `(expected, waitSeconds:)` (the positive forms also take `requireVisible:`). There is
no form that takes a selector.

## Functions

| function | negation | comparison |
|---|---|---|
| `select(selector).valueIs(expected, requireVisible:, strict:, waitSeconds:)` | `valueIsNot(expected, strict:, waitSeconds:)` | exact match |
| `valueContains(expected, requireVisible:, strict:, waitSeconds:)` | `valueContainsNot(expected, strict:, waitSeconds:)` | substring match |
| `valueStartsWith(expected, requireVisible:, strict:, waitSeconds:)` | `valueStartsWithNot(expected, strict:, waitSeconds:)` | prefix match |
| `valueEndsWith(expected, requireVisible:, strict:, waitSeconds:)` | `valueEndsWithNot(expected, strict:, waitSeconds:)` | suffix match |
| `valueMatches(pattern, requireVisible:, strict:, waitSeconds:)` | `valueMatchesNot(pattern, strict:, waitSeconds:)` | regular expression (substring; use `^…$` for a full match) |
| `valueMatchesDateFormat(format, requireVisible:, waitSeconds:)` | — | `DateFormatter` format string |
| `valueIsNotEmpty(strict:, waitSeconds:)` | `valueIsEmpty(strict:, waitSeconds:)` | non-empty / empty |

Comparison follows the same "same if it looks the same" rule as text assertions (`strict:` to
disable it) — see [Text Assertion](./text_assertion.md) for the full rule.

## Example

```swift
select("#email").valueIs("test@example.com")
select("#email").valueContains("@example.com")
```

## Notes

- On iOS, an empty text field can return its placeholder text as the value instead of an empty
  string — avoid asserting `valueIsEmpty` on such a field; check `valueIsNotEmpty` or a specific
  expected value instead where the field is populated.
- Negative forms and the empty checks do not consider visibility, and none of these commands take
  `scroll:` — same rules as text assertions.
- A chained check first evaluates against the value already grabbed, and only polls the device if
  that value doesn't yet satisfy the assertion — see [Text Assertion](./text_assertion.md).

### Link
- [index](../index.md)
