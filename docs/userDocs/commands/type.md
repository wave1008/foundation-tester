# type

Types text into a field, either the currently focused one or a specified element.

## Functions

| function | description |
|---|---|
| `type("some text", replace: false)` | Types into the **currently focused** element (focus it first with `tap(inputField)`). The argument is text, not a selector — passing something that looks like a selector (starts with `#`, or contains `\|\|` / `>>`) fails before execution rather than silently typing the literal string. To actually type such a string, use the two-argument form `type("#field", "#email")`. `replace: true` clears the field (like `clearInput`) before typing. |
| `type(sel, "some text", timeout:scroll:maxSwipes:replace:)` | Resolves the element, then types into it. Japanese text is typed as-is (no IME switching needed). `replace: true` clears the field before typing. |

## Example

```swift
tap("#field")
type("abc")                        // traditional form: focus, then type

type("#email", "test@example.com") // selector form: resolve + focus + type in one step
type("#note", "new contents", replace: true)
```

## Notes

- **Line breaks (`\n`) follow the OS default.** On iOS this arrives as a Return key press: it
  inserts a newline in a multi-line field, or fires the field's commit action (search, done, …)
  in a single-line field — which one happens depends on the field, not on `type`. On Android, a
  trailing newline is likewise sent as Enter. If the intent is to commit (search/submit), use
  [`pressEnter()`](./press_enter_hide_keyboard.md) instead — `type("watch\n")` does not tell the
  reader whether a newline or a submit was intended.
- **`tap(inputField)` → `type("some text")` is supported.** On Android, input fields are often a
  container (Material's `TextInputLayout`) wrapping the actual field (`TextInputEditText`), and
  the `#id` frequently resolves to the container. Tapping the container does not always move
  focus into the field inside it. When `type` finds that focus did not land in a field after the
  preceding `tap`, it locates the field by name and types into it instead:

  ```
  ✅ type "abc"(typed into textField (the preceding tap did not put a field in focus))
  ```

  This recovery only looks at the tree immediately after the tap, only targets the tapped
  element itself or the single input field inside it (nothing is guessed when there are two or
  more candidate fields), and is recorded as the note `type-focus-recovered`. If it cannot
  recover (the field is ambiguous), write the selector form instead —
  `type(sel, "some text")` resolves, focuses, and reads the value back in one step.

### Link
- [index](../index.md)
