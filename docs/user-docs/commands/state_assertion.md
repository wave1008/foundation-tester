# enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF

Checks on the enabled/disabled and checked/unchecked state of the last grabbed element.

## Functions

| function | description |
|---|---|
| `select(selector).enabledIsTrue(waitSeconds:)` | Asserts the element is enabled. Waits up to `waitSeconds` for a state change. The target is the element grabbed last. |
| `select(selector).enabledIsFalse(waitSeconds:)` | Asserts the element is disabled. Same waiting behavior. |
| `select(selector).checkIsON(prefer:, waitSeconds:)` | Asserts the element is checked. |
| `select(selector).checkIsOFF(prefer:, waitSeconds:)` | Asserts the element is not checked. Warns at the end of the run if the element never reported a checked state (on or off). |

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
- An element in an indeterminate (partially checked) state fails both `checkIsON` and `checkIsOFF`.

## Judging the checked state from images (CheckStateClassifier)

Parts whose accessibility reports no checked state can be judged by an image classifier trained from
sample images (same location and labels as Shirates' Vision edition).

```
<project>/vision/classifiers/CheckStateClassifier/
  [ON]/             sample images of the "on" state (png / jpg)
  [OFF]/            sample images of the "off" state
  [INDETERMINATE]/  sample images of the partially checked state (optional)
```

- Each sample should be **exactly the element's frame** cropped from a screenshot (the element is
  cropped the same way when it is judged).
- With samples in `[INDETERMINATE]`, a partially checked look is judged indeterminate and both `checkIsON` and
  `checkIsOFF` fail for that reason (a fleetest-specific label). Without them, it is judged on or off.
- The classifier always answers one of the sample labels. **If switches or radios on the same screen are judged
  too, add samples of them as well** (looks that are not in the samples are easy to misjudge).
- The first judgement trains the classifier (a few seconds). The result is kept under `.fleetest/` and
  is retrained only when the samples change.
- The run profile's `preferCheckStateClassifier` (default `true`) prefers the classifier over
  accessibility. With `false`, it is used only for elements whose accessibility reports no checked state.
- To change it for one command, pass the argument: `checkIsON(prefer: .classifier)` judges with the classifier when there
  are samples, and `checkIsON(prefer: .accessibility)` judges with accessibility for elements whose accessibility reports a
  checked state (elements that report none are still judged by the classifier). The choice is shown on the step in the report.
  `checkIsOFF` takes the same argument; when omitted, the run profile decides.
- Steps judged from the image carry the note `check-state-classified` in the results.
- When a check judged from the image fails, the screenshot the classifier judged is attached to the report
  right under the failed step, so you can see what it looked at.
- `options=` / `imageFilter=binary` in Shirates' `MLImageClassifier.swift` are read with the same meaning.
- [imageIs](image_assertion.md) uses the same mechanism to assert the label of an element's image.
- Capture and check samples with `fleetest vision capture --classifier CheckStateClassifier --label "[ON]" --selector "#…"`
  and `fleetest vision check` (details on the [imageIs](image_assertion.md) page).
- On Android, both `isChecked` and `isSelected` are considered — tabs and selectable rows that
  only report `isSelected` (not `isChecked`) are still recognized as checked.

### Link
- [index](../index.md)
