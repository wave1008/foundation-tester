# Any value assertion (thisIs, thisContains, ...)

[in Japanese(日本語)](any_value_assertion_ja.md)

Checks on values that don't touch the device — API responses, computed results. They attach
directly to strings, numbers, `Bool`, and optionals. A failure is recorded as one step, just like
any other command, and aborts the scenario the same way.

## Functions

| positive | negative | judgment |
|---|---|---|
| `thisIs(expected, strict:)` | `thisIsNot(expected, strict:)` | equal / not equal |
| `thisIsTrue()` | `thisIsFalse()` | `Bool` |
| `thisIsNotEmpty()` | `thisIsEmpty()` | not empty / empty string |
| `thisIsNotBlank()` | `thisIsBlank()` | not whitespace-only / whitespace only (empty counts as blank) |
| `thisContains(expected)` | `thisContainsNot(expected)` | substring match |
| `thisStartsWith(expected)` | `thisStartsWithNot(expected)` | prefix match |
| `thisEndsWith(expected)` | `thisEndsWithNot(expected)` | suffix match |
| `thisMatches(pattern)` | `thisMatchesNot(pattern)` | regular expression |
| `thisMatchesDateFormat(format)` | — | `DateFormatter` format |
| `thisIsGreaterThan(other)` / `thisIsGreaterThanOrEqual(other)` | — | numeric greater-than(-or-equal) (fails if the value can't be interpreted as a number) |
| `thisIsLessThan(other)` / `thisIsLessThanOrEqual(other)` | — | numeric less-than(-or-equal) (fails if the value can't be interpreted as a number) |

`strict:` on `thisIs` / `thisIsNot` (default `false`) switches the comparison rule, as in `textIs` and
friends. By default invisible characters (zero-width etc.) are ignored; `strict: true` normalizes
nothing. No other function takes `strict:`.

## Example

```swift
let total = select("#total").text    // e.g. a value read from the screen, or an httpRequest response
total.thisContains("1,200")
total.thisStartsWith("Total")
(10 * 3).thisIs(30)
"2026/07/27".thisMatchesDateFormat("yyyy/MM/dd")
stockCount.thisIsGreaterThan(0)
```

### Link
- [index](../../index.md)
