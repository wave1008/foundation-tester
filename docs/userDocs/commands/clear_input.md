# clearInput

Empties an input field.

## Functions

| function | description |
|---|---|
| `clearInput()` | Empties the currently focused input field. |
| `clearInput(sel, timeout:scroll:maxSwipes:)` | Empties the specified input field. |

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
  contents. If you only want to save a selector resolution, `type(sel, "文字列", replace: true)`
  folds the clear and the type into a single command. See [type](./type.md).
- On the Flutter iOS build, the in-app engine cannot clear the field itself and automatically
  falls back to the XCUITest engine for this one command (adds roughly one to two seconds).

### Link
- [index](../index.md)
