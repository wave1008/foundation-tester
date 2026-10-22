# Memo (writeMemo, readMemo, clearMemo, memoTextAs)

[in Japanese(日本語)](memo_ja.md)

Share values between scenarios. Every `@Test` runs as its own process, so a Swift variable does
not carry over; the memo is shared by **every scenario of the run, on every device** (see Scope below).

## Functions

| function | description |
|---|---|
| `writeMemo(key, text)` | Appends `text` to the key's history. |
| `readMemo(key) -> String` | Returns the **last** value written under the key, or `""` when there is none (not a failure; the step carries the note `memo-key-not-found`). |
| `clearMemo()` | Clears the whole memo. |
| `element.memoTextAs(key)` | Writes the grabbed element's text (the first non-empty of label and value) and returns the element. Fails if no element was grabbed. |
| `string.memoTextAs(key)` | Writes the string and returns it. |

## Scope

- The memo is shared by **every scenario of the run, on every device**. Nothing carries over to the
  next run.
- A single invocation (an MCP call, or running the scenario runner by hand) starts with an empty
  memo.
- The reliable pattern is **write in `beforeAll()`, read in each test**: `beforeAll()` runs once per
  run per class, before any scenario of that class on any device (other devices wait until it
  finishes), so the value exists wherever the scenarios land.
- If `beforeAll()` fails, the remaining scenarios of that class in the run are recorded as failed
  without running; it is never re-run. Values written in `setUpDevice()` (once per run, device and
  class) are also visible to the whole run, so the same key is overwritten by whichever device runs
  it later — don't use the memo for per-device values. If `setUpDevice()` fails, the remaining
  scenarios of that class on that device are recorded as failed without running.
- Limitations: a scenario receives the memo as it was **when the scenario started** — values another
  device writes while it runs are not visible to it. Concurrent writes from several devices are not
  serialized (no locking). `clearMemo()` clears the memo for the whole run. A run is one fleetest
  process: when a run is split across machines (`--fleet`, or a profile whose devices span several
  machines), each machine has its own memo and runs its own `beforeAll()`.
- `tearDownDevice()` and `afterAll()` can read the memo too (`afterAll()` runs after every device has
  finished the run, so it sees the final values).
- Trying to pass a value through a test-class property (`var`) produces a build warning when the writer
  and the reader run in different processes — written in one `@Test` and read in another, or written in
  `beforeAll()` and read in the tests. Writing in `beforeEach()` and reading in the same test or
  `afterEach()` works and is not flagged. Writes through helper functions and mutations such as
  `x.append(…)` are not detected, so no warning is not a guarantee.

## Example

```swift
@TestClass
class OrderFlow {
    func beforeAll() {
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
