# enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF

Checks on the enabled/disabled and checked/unchecked state of the last grabbed element.

## Functions

| function | description |
|---|---|
| `select(selector).enabledIsTrue(timeout:)` | Asserts the element is enabled. Waits up to `timeout` for a state change. The target is the element grabbed last. |
| `select(selector).enabledIsFalse(timeout:)` | Asserts the element is disabled. Same waiting behavior. |
| `select(selector).checkIsON(timeout:)` | Asserts the element is checked. |
| `select(selector).checkIsOFF(timeout:)` | Asserts the element is not checked. Warns at the end of the run if a checked state was never actually observed. |

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

- On iOS, whether the checked state can be read at all depends on the app's implementation — some
  elements never report it.
- On Android, both `isChecked` and `isSelected` are considered — tabs and selectable rows that
  only report `isSelected` (not `isChecked`) are still recognized as checked.

### Link
- [index](../index.md)
