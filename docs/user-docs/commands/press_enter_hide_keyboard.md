# pressEnter, hideKeyboard

Fires the keyboard's commit action, or closes the on-screen keyboard.

## Functions

| function | description |
|---|---|
| `pressEnter()` | Fires the Enter / IME action (search, done, submit, newline …) on the currently focused input. |
| `hideKeyboard()` | Closes the on-screen keyboard. **Android only**; presses the back key only when a keyboard is showing, so it is safe to call unconditionally. The next action (such as `tap`) waits until the screen information no longer reports the keyboard before it looks for its element (on some devices the keyboard stays reported for a few seconds after it closes, hiding elements at the bottom edge). **Not supported on iOS** — it fails there. Use `pressEnter()` instead (this closes the keyboard on a single-line field). |

## Example

```swift
type("#search_box", "watch")
pressEnter()               // fires the field's commit action

android {
    hideKeyboard()
}
```

## Notes

- Whether `pressEnter()` inserts a newline or fires a commit action depends on the field, not on
  the command — see [type](./type.md) for the same question about a trailing `\n` in `type`.
- Verifying whether the keyboard is showing is a separate assertion; see
  [keyboard assertions](./keyboard_assertion.md).

### Link
- [index](../index.md)
