# clearInput

[in Japanese(日本語)](clear_input_ja.md)

Empties an input field.

## Functions

| function | description |
|---|---|
| `clearInput(settle:)` | Empties the currently focused input field. When no element in the screen's element list reports focus, it cannot check that the field was emptied, so it passes with the note `clear-input-unverified` (check the value with `textIs`). |
| `clearInput(sel, settle:waitSeconds:scroll:maxSwipes:)` | Empties the specified input field. |

## Example

```swift
tap("#note")
clearInput()
type("new content")

clearInput("#note")
type("#note", "new content")

// one step instead of clearInput + type
type("#note", "new content", replace: true)
```

## Notes

- **Pointing it at a button or another non-input element fails before anything is cleared.** `clearInput` taps its
  target first, so clearing a button would press it (a submit or a purchase). It refuses whatever the UI framework (Compose and Flutter
  included), only when the element's type is a button, switch, link and so on. Pointing at an
  element that wraps exactly one input field is not refused (it runs as before).
- **Whitespace cannot be verified.** Whitespace-only content is invisible to accessibility, so the tool cannot verify that it was cleared, and a lost trailing/middle space after `type` is not detected either — assert values where whitespace matters with `textIs`.

- `type` appends rather than overwrites, so clear the field first when you need to replace its
  contents. If you only want to save a selector resolution, `type(sel, "some text", replace: true)`
  folds the clear and the type into a single command. See [type](./type.md).
- On the Flutter iOS build, the in-app engine cannot clear the field itself and automatically
  falls back to the XCUITest engine for this one command (adds roughly one to two seconds).
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

### Link
- [index](../../index.md)
