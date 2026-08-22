# Reading Values (lastElement, .text, .value, .id)

How to read a grabbed element's own data — its label, value, and identifier — instead of just
asserting against it.

## Grabbing an element's value (`.text` / `.value` / `.id`)

The return value of `exist` (and `select`) exposes the value itself. Use this when the expected
value can't be written into the scenario in advance — capturing an order number to check on a
later screen, or reading a total shown on screen to use in a calculation.

```swift
var orderNumber: String?

scene(2, "Confirm the order and note the order number") {
    action { tap("#btn_order") }
    .expectation {
        select("#order_id").textStartsWith("Order:")   // settle the value first, then read it
        orderNumber = exist("#order_id").text
    }
}
scene(3, "The confirmation screen shows the same order number") {
    action { tap("#tab_orders") }
    .expectation { select("#confirm_order_id").textIs(orderNumber ?? "") }
}
```

- `.text` is the element's displayed label, `.value` is its value, `.id` is its identifier.
- The value is **the one `exist` matched at that moment** — reading `.text` afterwards does not
  re-fetch the screen (no extra device round trip, no extra recorded step). Re-run `exist` if you
  need the latest value.
- **Don't read a screen that's still updating.** The element itself may already exist, so `exist`
  succeeds immediately and grabs a stale value. Settle the value first with `textIs` /
  `textStartsWith` / etc., as in the example above, then read it.
- The value is `nil` when the element couldn't be grabbed, when the step was skipped after a
  failure, or during a dry run — so that "read a value from an element that wasn't grabbed" can
  never silently succeed.
- **Check whether the grab succeeded with `.isEmpty` / `.isNotEmpty`, not `.text == nil`** — a
  grabbed element with no label (e.g. an icon-only button) also reads `.text` as empty, which
  `.text == nil` would misreport as "not grabbed."

```swift
let e = select("#total")
if e.isNotEmpty { total = e.text }   // absent or invisible → an empty element, so don't read it
```

- To read a value without leaving a verification step in the report, use `select` instead of
  `exist` — `select` only grabs, and is not subject to visibility checks
  (`select("#total").text`).

## The last grabbed element (`lastElement`)

Even without capturing the return value, the element grabbed last is readable via `lastElement`.

```swift
select("#total")
lastElement.text.thisContains("1,200")   // readable without assigning to a variable
tap("#order_btn")
lastElement.idIs("order_btn")            // operation commands also replace the grabbed element
```

- **What replaces it**: any command that resolves to exactly one element (`select` / `exist` /
  `tap` / `type` / `waitForDisplay` / the text/value/id/state assertions). `notExist` and
  `countIs` do **not** replace it (they don't resolve to one element), and commands that take no
  selector (`swipe`, `launchApp`, etc.) don't either.
- `.text` / `.value` / `.id` are frozen at the moment the element was grabbed, same as `exist`'s
  return value — scrolling or tapping in between makes them stale. Read right after grabbing, or
  capture into a variable (`let e = select(…)`) if you need it later.
- **The grabbed element is cleared to empty on scene boundaries**, and overwritten with an empty
  element whenever a grab fails (so a value from an earlier, different element is never read as
  "just grabbed"). Reading it before anything has ever been grabbed produces an empty element with
  a warning.

## First-check-the-grabbed-value order

A chained check (`exist(…).textIs(…)`, `lastElement.textIs(…)`, or the implicit `textIs(…)`)
first evaluates against the value already grabbed. If that already satisfies the assertion, the
step is still recorded, but with no device round trip — the message shows
`(from the grabbed value)`. Otherwise it polls the device as usual up to `timeout`.

```swift
exist("#total").textIs("1,200")   // 0 round trips if the grabbed value is already "1,200"
tap("#reload_btn")
lastElement.textIs("1,500")       // the grabbed value is stale → re-fetches until it becomes "1,500"
```

The longer you wait after grabbing before checking, the more likely a stale value happens to
match by coincidence and passes without waiting for the real update — be especially careful with
`lastElement` used far from where it was grabbed.

### Link
- [index](../index.md)
