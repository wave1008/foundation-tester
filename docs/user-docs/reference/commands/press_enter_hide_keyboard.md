# pressEnter, hideKeyboard

[in Japanese(日本語)](press_enter_hide_keyboard_ja.md)

Fires the keyboard's commit action, or closes the on-screen keyboard.

## Functions

| function | description |
|---|---|
| `pressEnter(settle:)` | Fires the Enter / IME action (search, done, submit, newline …) on the currently focused input. |
| `hideKeyboard(settle:)` | Closes the on-screen keyboard. Does nothing when no keyboard is showing, so it is safe to call unconditionally. On **Android** it presses the back key. On **iOS** it taps an empty spot above the keyboard (a point that is on no element, or only on a screen-wide container you cannot operate; never on text, images, buttons or input fields, a toast, or the status bar), and if the keyboard is still showing it presses Enter. The next action (such as `tap`) waits until the screen information no longer reports the keyboard before it looks for its element (Android; on some devices the keyboard stays reported for a few seconds after it closes, hiding elements at the bottom edge). |

## Example

```swift
type("#search_box", "watch")
pressEnter()               // fires the field's commit action

android {
    hideKeyboard()
}
```

## Notes

- Whether `pressEnter(settle:)` inserts a newline or fires a commit action depends on the field, not on
  the command — see [type](./type.md) for the same question about a trailing `\n` in `type`.
- **iOS `hideKeyboard()`**: which framework closes on a tap of the background differs. In our measurements on the iOS Simulator, a background tap closes the keyboard in Compose Multiplatform, while SwiftUI and Flutter close on the Enter that follows. If neither closes it, the step fails. The step note names the tapped point. When the tap did not close the keyboard and Enter was sent, the note says that Enter also fires the field's return-key action (search, submit, next field). If elements above the keyboard disappeared after the tap, the note asks you to check that nothing was triggered.
- **A target under the keyboard**: when `tap` / `type` / `clearInput` finds that the target's centre is under the keyboard, it first scrolls the container, then closes the keyboard by a means with no side effect (iOS: the background tap above; Android: the back key) and acts. If the keyboard cannot be closed that way, the step fails without touching anything — the return key would close it but also fires the field's action, so it is never pressed automatically. Call `pressEnter()` before the step if that is what you want. On Android, when the target is not found while the keyboard is showing (the window shrinks above the keyboard and elements below it leave the tree), the keyboard is closed with the back key and the target is looked up once more.
- Verifying whether the keyboard is showing is a separate assertion; see
  [keyboard assertions](./keyboard_assertion.md).
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

### Link
- [index](../../index.md)
