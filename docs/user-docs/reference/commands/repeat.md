# repeatWhileCanSelect, doUntilTrue

[in Japanese(日本語)](repeat_ja.md)

Repeats a block while a selector resolves, or until an arbitrary condition becomes true.

## Functions

| function | description |
|---|---|
| `repeatWhileCanSelect(sel, maxLoopCount: 10, waitSeconds: 0, title:) { }` | Repeats the block while the selector keeps resolving. For an unknown number of matching items (e.g. dismissing a variable number of cards). Reaching `maxLoopCount` is not a failure, but it is recorded. |
| `doUntilTrue("description", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { condition }` | Repeats the block until it returns true. You can call commands such as `scrollDown()` and `select(...)` inside the block. A thrown error fails immediately without retrying. |

## Example

```swift
repeatWhileCanSelect("#dismiss_card", maxLoopCount: 10) {
    tap("#dismiss_card")
}

doUntilTrue("background job finished", waitSeconds: 10, intervalSeconds: 0.5) {
    select("#job_status").text == "done"
}

doUntilTrue("scroll down until Settings shows") {
    scrollDown()
    return select("Settings").isNotEmpty
}
tap("Settings")
```

## Notes

- `repeatWhileCanSelect`'s `maxLoopCount:` only caps a runaway loop — it is not an assertion that the
  loop ran a specific number of times.
- If all you want is to wait for an element to appear or disappear, use `waitForDisplay` /
  `waitForClose` or a command's `waitSeconds:` instead of `doUntilTrue` — those already poll, and
  they record a single step.
- Each attempt is recorded as a group named `"<description> #n"`, followed by one step with the
  result. If a command inside the block fails, the scenario stops there.
- `doUntilTrue` stops only on `waitSeconds:` and `maxLoopCount:` (the 120-second cap of a single
  command does not apply). Time the step slowdown spent waiting before an action inside the block is subtracted from that limit.
- A `throw` inside the condition block fails the step immediately (no further retries) —
  reserve throwing for a condition that can never become true, not for a transient read error.

### Link
- [index](../../index.md)
