# Any value assertion (thisIs, thisContains, ...)

[in Japanese(日本語)](any_value_assertion_ja.md)

Checks on values that don't touch the device — API responses, computed results. They attach
directly to strings, numbers, `Bool`, and optionals. A failure is recorded as one step, just like
any other command, and aborts the scenario the same way.

## Functions

| function | judgment |
|---|---|
| `thisIs(expected)` / `thisIsNot(expected)` | equal / not equal |
| `thisIsTrue()` / `thisIsFalse()` | `Bool` |
| `thisIsEmpty()` / `thisIsNotEmpty()` | empty string |
| `thisIsBlank()` / `thisIsNotBlank()` | whitespace only (empty counts as blank) |
| `thisContains(Not)` / `thisStartsWith(Not)` / `thisEndsWith(Not)` | substring / prefix / suffix match |
| `thisMatches(Not)` / `thisMatchesDateFormat(format)` | regular expression / `DateFormatter` format |
| `thisIsGreaterThan(other)` / `thisIsGreaterThanOrEqual(other)` | numeric greater-than(-or-equal) (fails if the value can't be interpreted as a number) |
| `thisIsLessThan(other)` / `thisIsLessThanOrEqual(other)` | numeric less-than(-or-equal) (fails if the value can't be interpreted as a number) |

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
