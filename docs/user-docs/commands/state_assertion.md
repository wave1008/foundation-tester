# enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF

Checks on the enabled/disabled and checked/unchecked state of the last grabbed element.

## Functions

| function | description |
|---|---|
| `select(selector).enabledIsTrue(timeout:)` | Asserts the element is enabled. Waits up to `timeout` for a state change. The target is the element grabbed last. |
| `select(selector).enabledIsFalse(timeout:)` | Asserts the element is disabled. Same waiting behavior. |
| `select(selector).checkIsON(timeout:)` | Asserts the element is checked. |
| `select(selector).checkIsOFF(timeout:)` | Asserts the element is not checked. Warns at the end of the run if the element never reported a checked state (on or off). |

All four are chainable on the return value of `exist` / `select`, and each also has an implicit
free-function form that acts on the last grabbed element (e.g. `enabledIsTrue()`).

## Example

```swift
select("#login_btn").enabledIsFalse()
tap("#email"); type("test@example.com")
tap("#password"); type("password123")
select("#login_btn").enabledIsTrue()

select("#toggle_notifications").checkIsON()
```

## Notes

- The checked state is read from accessibility. iOS implementations report it in different ways and
  fleetest reads all of them (the selected trait, a switch value of `"1"`/`"0"`, React Native's
  `"checkbox, checked"` and so on).
- **Some elements never report a checked state** (for example a checkbox built from a SwiftUI `Button`).
  `checkIsON` on such an element fails with "reports no check state". Verify a text that reflects the
  state with `textIs`, or have the app expose it (in SwiftUI, `.accessibilityRepresentation { Toggle(...) }`).
- **Implementations that report only "on"** (Compose checkboxes on iOS, for example): once the same
  scenario has seen the element on, a missing report is read as off. `checkIsOFF` on an element that was
  never seen on passes without knowing the state, and a warning is shown at the end of the run.
- An element in a mixed (partially checked) state fails both `checkIsON` and `checkIsOFF`.
- On Android, both `isChecked` and `isSelected` are considered — tabs and selectable rows that
  only report `isSelected` (not `isChecked`) are still recognized as checked.

### Link
- [index](../index.md)
