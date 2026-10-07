# Memo (writeMemo, readMemo, clearMemo, memoTextAs)

Share values between scenarios. Every `@Test` runs as its own process, so a Swift variable does
not carry over; the memo carries over **to later scenarios on the same device** (not to other
devices — see Scope below). Names and behavior follow Shirates.

## Functions

| function | description |
|---|---|
| `writeMemo(key, text)` | Appends `text` to the key's history. |
| `readMemo(key) -> String` | Returns the **last** value written under the key, or `""` when there is none (not a failure; the step carries the note `memo-key-not-found`). |
| `clearMemo()` | Clears the whole memo. |
| `element.memoTextAs(key)` | Writes the grabbed element's text (the first non-empty of label and value) and returns the element. Fails if no element was grabbed. |
| `string.memoTextAs(key)` | Writes the string and returns it. |

## Scope

- The memo is shared by the scenarios that run **on the same device in one run**. A value written
  on another device is not visible (`readMemo` returns `""` with `memo-key-not-found`). Nothing
  carries over to the next run.
- A single invocation (an MCP call, or running the scenario runner by hand) starts with an empty
  memo.
- The reliable pattern is **write in `setUpDevice()`, read in each test**: the first scenario that
  lands on a device runs `setUpDevice()` first, so the value exists wherever the others land.
- If `setUpDevice()` fails, the remaining scenarios of that class on that device are recorded as
  failed without running. It runs at most once per device in a run, even when its outcome is
  unknown, and is not re-run after the device recovers.
- `tearDownDevice()` can read the memo too (it runs after the device has finished its work, so it
  sees the final values).
- Trying to pass a value through a test-class property (`var`) produces a build warning when the writer
  and the reader run in different processes — written in one `@Test` and read in another, or written in
  `setUpDevice()` and read in the tests. Writing in `beforeEach()` and reading in the same test or
  `afterEach()` works and is not flagged. Writes through helper functions and mutations such as
  `x.append(…)` are not detected, so no warning is not a guarantee.

## Example

```swift
@TestClass
class OrderFlow {
    func setUpDevice() {
        launchApp()
        select("#shop_name").memoTextAs("shop")
    }

    @Test("the receipt shows the shop")
    func S0010() {
        scenario {
            scene(1, "Check") {
                expectation { select("#receipt_shop").textIs(readMemo("shop")) }
            }
        }
    }
}
```

### Link
- [index](../../index.md)
