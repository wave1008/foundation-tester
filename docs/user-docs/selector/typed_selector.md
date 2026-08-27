# Typed Selector (`Sel`)

A selector expression is a single string, so a typo can't be caught by the compiler — only
by the runtime syntax check. `Sel` is a type-checked, autocompleted way to write the same
selector notation, offered alongside the string form (not a replacement for it).

## Examples

```swift
tap(.id("login_btn"))                            // #login_btn
tap(.id("login_btn").or(.text("Log In")))         // #login_btn||Log In
tap(.id("list").find(.type(.cell).nth(2)))        // #list >> .cell[2]
tap(.text("Notification").right(.switch))         // Notification:rightSwitch
exist(.type(.button).text("Save", .contains))     // .button&&textContains=Save
tap(.type(.button).not(.text("Cancel")))           // .button&&text!=Cancel
```

Every command that takes a selector has both a `String` overload and a `Sel` overload — use
whichever reads better in a given line; they build the exact same underlying locator, so
execution, reporting, and self-healing behave identically either way.

## Vocabulary

- `.id(_)`, `.text(_)`, `.value(_)`, `.placeholder(_)` — each takes an optional second
  argument `mode`, one of `.exact` (the default) / `.contains` / `.startsWith` / `.endsWith` /
  `.matches`. Also `.type(_)`, `.checked(_)`, `.enabled(_)`, `.nth(_)` (1-origin ordinal).
- Compose with `.or(_)` (union) and `.find(_)` (scope into a descendant).
- Exclude with `.not(_)` — the typed form of the string notation's `attr!=value` / `!value`.
  Pair it with a positive condition, exactly as the string form requires: a clause of only a
  negation matches containers and layout nodes too. If the argument itself contains `.or(_)`,
  **every** alternative is excluded.
- Relative: `.right(_)`, `.left(_)`, `.above(_)`, `.below(_)` — take an optional `matching:`
  filter and `nth:` (nearest-first ordinal), mirroring the string form's relative selector.
- Type names: `.button`, `.staticText`, `.textField`, `.secureTextField`, `.switch`, plus
  aliases `.input`, `.widget`, and `.cell`, `.image`, `.clickable`. Anything outside this
  vocabulary is `.custom("...")`.

Filter methods (`.text`, `.type`, `.nth`, …) always apply to the **current target**: before a
relative step that's the anchor, after a relative step that's the resolved candidate.

## Notes

- A misspelled member name (`.buton`) is a **compile error** in `Sel`, unlike the string
  form's `"buton"` (which is a runtime syntax error at best, or silently a literal label at
  worst).
- **`scrollFrame:` stays string-only** — there is no `Sel` overload for that one argument,
  even on commands that otherwise have a full `Sel` overload.
- Generated code (from the VS Code extension's live-operation recording, or agent-driven
  scenario authoring) writes the **string form by default**. `Sel` is there for people who
  prefer to write it by hand.

See [Selector expression](./selector_expression.md) for the full notation this maps to.

### Link
- [index](../index.md)
