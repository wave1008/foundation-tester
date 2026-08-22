# Selecting Elements and Asserting

This page covers the basics of grabbing an element and verifying its state: the difference
between `tap`, `exist`, and `select`, and how the value/text assertion commands target
"whatever was grabbed last."

## `tap` vs. `exist` vs. `select`

- **`tap(sel)`** resolves the selector and performs a tap. If nothing matches, the command
  fails and the scenario aborts.
- **`exist(sel)`** is an assertion: it fails (aborts the scenario) if nothing matches, and
  its result is recorded as a check in the report. Its return value can be chained into
  further assertions.
- **`select(sel)`** only grabs an element — no device interaction, no visibility check by
  default beyond what's asked. If nothing matches, it does **not** fail; it returns an empty
  element instead, and `select` is **not** recorded as an assertion in the report (so it
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
same set works as an implicit (no-argument) call, as shown above.

## Implicit waiting

Element lookups retry until a timeout instead of failing on the first miss:

- **Operations (`tap`, `type`, …)**: default `timeout:` is about 0.7 seconds.
- **`select` and assertion commands (`exist`, `textIs`, …)**: default `timeout:` is 5
  seconds (the run profile's `defaultTimeout`).

Both accept an explicit `timeout:` (fractional seconds allowed, e.g. `timeout: 1.2`) to
override the default for a single call.

## Visibility and false-positive checks

`requireVisible: false` skips the covered/off-screen check that normally backs `exist`
(where it flips a match to failure) and `select` (where it returns an empty element). This
extra visibility pass only actually runs on runs where the run profile has
`falsePositiveCheck: true` — on other runs the flag has nothing to skip.

### Link
- [index](../index.md)
