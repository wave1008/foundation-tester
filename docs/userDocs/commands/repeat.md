# repeatWhileCanSelect, doUntilTrue

Repeats a block while a selector resolves, or until an arbitrary condition becomes true.

## Functions

| function | description |
|---|---|
| `repeatWhileCanSelect(sel, max: 10, waitSeconds: 0) { }` | Repeats the block while the selector keeps resolving. For an unknown number of matching items (e.g. dismissing a variable number of cards). Reaching `max` is not a failure, but it is recorded. |
| `doUntilTrue("description", waitSeconds: 10, intervalSeconds: 0.5, maxLoopCount: 100) { condition }` | Repeats until `condition` (`() async throws -> Bool`) returns true. For app or external state you cannot express as a selector — not for waiting on an element (use each command's `timeout:` for that). A thrown error fails immediately without retrying. |

## Example

```swift
repeatWhileCanSelect("#dismiss_card", max: 10) {
    tap("#dismiss_card")
}

doUntilTrue("background job finished", waitSeconds: 10, intervalSeconds: 0.5) {
    select("#job_status").text == "done"
}
```

## Notes

- `repeatWhileCanSelect`'s `max:` only caps a runaway loop — it is not an assertion that the
  loop ran a specific number of times.
- **`doUntilTrue` is for state that a selector cannot express** — polling an external process,
  a value derived from several reads, or app state that outlives the current screen. If what
  you are waiting for is simply "an element appears/disappears", use `waitForDisplay` /
  `waitForClose` or a command's `timeout:` instead — those already poll.
- `doUntilTrue`'s `waitSeconds:` cannot exceed the per-step wall-clock cap of 120 seconds; a
  larger value does not actually wait longer.
- A `throw` inside the condition block fails the step immediately (no further retries) —
  reserve throwing for a condition that can never become true, not for a transient read error.

### Link
- [index](../index.md)
