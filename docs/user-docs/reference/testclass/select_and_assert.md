# Select and assert

[in Japanese(日本語)](select_and_assert_ja.md)

This page covers the basics of grabbing an element and verifying its state: the difference
between `tap`, `exist`, and `select`, and how the value/text assertion commands target
"whatever was grabbed last."

## `tap` vs. `exist` vs. `select`

- **`tap(sel)`** resolves the selector and performs a tap. If nothing matches, the command
  fails and the scenario aborts.
- **`exist(sel)`** is an assertion: it fails (aborts the scenario) if nothing matches, and
  its result is recorded as a check in the report. Its return value can be chained into
  further assertions.
- **`select(sel)`** only grabs an element — no device interaction. Like `exist`, it checks by
  default that the element is actually visible, but when nothing matches or the element is not
  visible (covered or clipped), it does **not** fail; it returns an empty element instead (pass
  `requireVisible: false` to skip the visibility check), and `select` is **not** recorded as an assertion in the report (so it
  won't count toward "at least one assertion" checks). Use it when you want to read a value,
  or chain an assertion, without adding an extra checkpoint to the report.

## Assertions target "the element grabbed last," not a selector

Text/value assertion commands (`textIs`, `valueIs`, and the rest of that family — see
[Text assertions](../commands/text_assertion.md)) do not take a selector. You grab an
element first, then assert on it. These three forms are exactly equivalent:

```swift
select("#login_btn").textIs("Log In")            // chained on the return value
select("#login_btn"); lastElement.textIs("Log In") // grabbed element made explicit
select("#login_btn"); textIs("Log In")            // implicit — acts on the last-grabbed element
```

`textIs("#login_btn", "Log In")` — passing the selector directly to the assertion — **does
not compile**. Grab first, assert second.

## Chaining off `exist`

```swift
exist("#total")
    .textStartsWith("Total")
    .textEndsWith("USD")
```

Any command that operates on a single already-grabbed element can chain this way, and the
same set works as an implicit (no-selector) call on the element `exist` just grabbed:

```swift
exist("#total"); textStartsWith("Total")
```

## Implicit waiting

Element lookups retry until a timeout instead of failing on the first miss:

- **Operations (`tap`, `type`, …)**: default `waitSeconds:` is about 0.7 seconds.
- **`select` and assertion commands (`exist`, `textIs`, …)**: default `waitSeconds:` is 5
  seconds (the run profile's `defaultTimeout`).

Both accept an explicit `waitSeconds:` (fractional seconds allowed, e.g. `waitSeconds: 1.2`) to
override the default for a single call.

## Visibility and text visual verification

`requireVisible: false` skips the covered/off-screen check that normally backs `exist`
(where it flips a match to failure) and `select` (where it returns an empty element). This
extra visibility pass is on by default (it does not run when both `fmTextOcclusionCheck` and
`ocrTextOcclusionCheck` are set to `false`, and then the flag has nothing to skip).

### Link
- [index](../../index.md)
