# idIs

Asserts the identifier of the last grabbed element.

## Functions

| function | description |
|---|---|
| `select(selector).idIs(expected, strict:, waitSeconds:)` | Asserts the identifier of the element equals `expected`. The target is the element grabbed last; also available as the implicit `idIs(expected, strict:, waitSeconds:)`. |

Comparison follows the same "same if it looks the same" rule as text assertions (see
[Text Assertion](./text_assertion.md)); pass `strict: true` to disable normalization.

## Example

```swift
exist("#login_btn").idIs("login_btn")
select("#row_01"); idIs("row_01")
```

### Link
- [index](../index.md)
