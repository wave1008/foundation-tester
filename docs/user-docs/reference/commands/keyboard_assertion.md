# Keyboard assertion (keyboardIsShown, keyboardIsNotShown)

[in Japanese(日本語)](keyboard_assertion_ja.md)

Checks whether the soft keyboard is shown. Opening and closing are animated, so both poll up to
`waitSeconds`. Omitted, it is the run profile's default wait (5 seconds as shipped).

## Functions

| function | description |
|---|---|
| `keyboardIsShown(waitSeconds:)` | Asserts the soft keyboard is shown. |
| `keyboardIsNotShown(waitSeconds:)` | Asserts the soft keyboard is hidden. |

## Example

```swift
tap("#email")
keyboardIsShown()
tap("#login_btn")
keyboardIsNotShown()
```

## Notes

- **"Hidden" can only be confirmed on the iOS in-app engine and on Android.** The iOS xcuitest
  engine can only say "keyboard seen" or "unknown" — it never confirms absence. On that engine,
  `keyboardIsNotShown` fails: with "keyboard is still shown" if it is visible, or "cannot
  determine the keyboard state" if not — unknown is never read as hidden, to avoid a false
  success.

### Link
- [index](../../index.md)
