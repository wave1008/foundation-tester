# ifCanSelect, ios, android

Conditional execution: run a block only when a selector resolves, or only on one OS.

## Functions

| function | description |
|---|---|
| `ifCanSelect(sel, waitSeconds: 0) { }.ifElse { }` | Runs the block when the selector resolves. Decides immediately, once, unless `waitSeconds:` is given. `.ifElse { }` is optional and runs when it does not resolve. |
| `ios { }` | Runs the block only when the current platform is iOS. |
| `android { }` | Runs the block only when the current platform is Android. |

## Example

```swift
tap("#request_location")
ifCanSelect("Allow While Using App", waitSeconds: 3) {
    tap("Allow While Using App")     // does nothing if it never appeared (already granted)
}.ifElse {
    // optional: runs when the selector did not resolve
}

expectation {
    ios { notExist("#ios_only_banner") }
    android { notExist("#android_only_banner") }
}
```

## Notes

- **`ifCanSelect` decides immediately by default** — it checks once, right away. Pass
  `waitSeconds:` (decimal allowed) to poll for that long before deciding "not found".
- Use it to neutralize a dialog or banner that may or may not appear, or for any one-off branch
  a scenario needs. There is no separate "may or may not appear" argument on other commands —
  that case is always expressed with `ifCanSelect`.
- **Declared interruptions are closed before the condition is answered.** If an
  [`irregularHandler`](./irregular_handler.md) covers the target element, `ifCanSelect` closes
  it first and then judges — otherwise a covered element would silently read as "not found" and
  the scenario would take the wrong branch instead of failing loudly.
- foundation-tester does not have Shirates's `ifTrue` / `ifFalse` / `ifScreenIs` family.
  Branching is deliberately kept to two forms: plain Swift `if` (for values you already read)
  and `ifCanSelect` (for "is this on screen").
- `ios { }` / `android { }` are for scenarios shared between both platforms where a small piece
  of behavior only applies to one of them — for example, an OS-specific banner check inside a
  shared `expectation { }`.

### Link
- [index](../index.md)
