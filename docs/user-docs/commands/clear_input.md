# clearInput

Empties an input field.

## Functions

| function | description |
|---|---|
| `clearInput()` | Empties the currently focused input field. |
| `clearInput(sel, timeout:scroll:maxSwipes:)` | Empties the specified input field. Whitespace-only content is invisible to accessibility, so the tool cannot verify that it was cleared, and a lost trailing/middle space after `type` is not detected either — assert values where whitespace matters with `textIs`. |

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

- `type` appends rather than overwrites, so clear the field first when you need to replace its
  contents. If you only want to save a selector resolution, `type(sel, "some text", replace: true)`
  folds the clear and the type into a single command. See [type](./type.md).
- On the Flutter iOS build, the in-app engine cannot clear the field itself and automatically
  falls back to the XCUITest engine for this one command (adds roughly one to two seconds).

### Link
- [index](../index.md)
