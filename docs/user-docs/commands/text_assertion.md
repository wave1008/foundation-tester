# Text Assertion

Checks on an element's label (its displayed text).

**The target is always "the element grabbed last" — selectors are not passed to these
commands.** First grab the element with `select` (or `exist` / `tap` / etc.), then verify it.
The following three forms mean exactly the same thing, with the same recorded steps and the
same number of device round trips:

```swift
select("#msg").textIs("Done")             // chain onto the return value
select("#msg"); lastElement.textIs("Done") // explicit lastElement
select("#msg"); textIs("Done")             // implicit (the last grabbed element)
```

Arguments are `(expected, timeout:)` (the positive forms also take `requireVisible:`). There is
no form that takes a selector — `textIs("#msg", "Done")` does not compile.

## Functions

| function | negation | comparison |
|---|---|---|
| `select(selector).textIs(expected, timeout:, requireVisible:, strict:)` | `textIsNot(expected, timeout:, strict:)` | exact match |
| `textContains(expected, timeout:, requireVisible:, strict:)` | `textContainsNot(expected, timeout:, strict:)` | substring match |
| `textStartsWith(expected, timeout:, requireVisible:, strict:)` | `textStartsWithNot(expected, timeout:, strict:)` | prefix match |
| `textEndsWith(expected, timeout:, requireVisible:, strict:)` | `textEndsWithNot(expected, timeout:, strict:)` | suffix match |
| `textMatches(pattern, timeout:, requireVisible:, strict:)` | `textMatchesNot(pattern, timeout:, strict:)` | regular expression (substring; use `^…$` for a full match) |
| `textMatchesDateFormat(format, timeout:, requireVisible:)` | — | `DateFormatter` format string, e.g. `"yyyy/MM/dd"` |
| `textIsNotEmpty(timeout:, strict:)` | `textIsEmpty(timeout:, strict:)` | non-empty / empty |

All of the above are chainable on the return value of `exist` / `select`, and each also has an
implicit one-argument free-function form that acts on the last grabbed element.

## Example

```swift
select("#msg").textIs("Done")

exist("#total")
    .textStartsWith("Total")
    .textEndsWith("USD")
```

## Notes

- **Comparison is "same if it looks the same."** Invisible characters (zero-width, bidi control,
  soft hyphen, etc.) are ignored, but visually different strings are treated as different —
  a half-width and a full-width space are different, and leading/trailing/repeated spaces are
  preserved. Pass `strict: true` to disable this normalization
  (`textIs("Done", strict: true)`). A mismatch failure message says whether the normalized or
  strict comparison would have matched.
- The element is assumed to already exist; these commands wait up to `timeout` for the value to
  change, so they can be used to wait for a value update.
- Negative forms and the empty checks (`textIsNot`, `textIsEmpty`, etc.) do not consider
  visibility — "not visible" cannot be confirmed from a screen match.
- **There is no `scroll:` on any of these.** They verify a static screen; scroll the target into
  view first with `select(selector, scroll: .down)` or similar.
- When chained onto `exist(…)` / `select(…)` / `lastElement`, the check first evaluates against
  the value already grabbed. If that already satisfies the assertion, the step is recorded but no
  device round trip happens (the message shows `(from the grabbed value)`). Otherwise it polls the
  device as usual up to `timeout`.

### Link
- [index](../index.md)
