# Custom Commands

When the built-in DSL commands don't cover a repeated step in your own app (log in, a shared
precondition, a custom multi-finger gesture assembled with [`gesture`](../commands/gestures.md)),
write it as a **plain Swift function** under `scenarios/`. This is what Shirates calls a `macro` —
in fleetest it's not a separate mechanism, just a function.

```swift
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

Call it like any other step inside a `scene`:

```swift
scene(1, "Sign in") {
    action {
        login(user: "demo@example.com", password: "hunter2")
    }
}
```

## Publishing it to the command index (`@FTCommand`)

A plain function like the one above works, but it doesn't show up anywhere — an agent writing
scenarios with the MCP server (`ft_dsl_commands`) or the `fleetest-scenario` skill has no way to
know it exists, so it never reuses it and may write the same steps out by hand instead. Mark the
function with `@FTCommand("summary")` to publish it:

```swift
@FTCommand("Logs in with email and password and waits for the home screen")
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

`fleetest api dsl-commands --project <name>` and the MCP tool `ft_dsl_commands` (called with
`project:` — it defaults to your only project, or the project the VSCode extension is set up
for) now list it alongside the built-in commands, tagged `[project: file:line]` so its origin is
clear. An agent asked to write a new scenario is told to prefer it over inventing similar steps
by hand, because it encodes your team's own conventions (e.g. what "logged in" means for your
app).

`@FTCommand` is a marker only — it generates no code. The function behaves exactly the same
whether or not it's marked; marking it only makes it discoverable.

### `extension FTElement` methods

A helper that acts on a grabbed element can be written as an `FTElement` extension instead of a
free function, so it chains the same way built-in commands like `.textIs(...)` do:

```swift
extension FTElement {
    @FTCommand("Taps this element and checks that the next element appears")
    @discardableResult
    func tapAndConfirm(_ next: String) -> FTElement {
        tap()
        return exist(next)
    }
}
```

```swift
select("#btn_add_to_cart").tapAndConfirm("#txt_cart_badge")
```

The index marks this kind of entry so a reader knows it's called as `select(...).tapAndConfirm(...)`,
not as a free function.

## Rules

- `@FTCommand` can only be attached to a **top-level function**, or a **method inside an
  `extension`** (an `extension FTElement { }` block, most commonly). A method inside a `class` or
  `struct` body is rejected at compile time — write it as a top-level function or move it into an
  extension.
- The argument is one non-empty string literal: `@FTCommand("what it does")`.
- Giving it the same name as a built-in DSL command (`tap`, `type`, …) is flagged as a warning in
  the index reply — pick a different name, since a reader can't tell which one a call means.
- A `private`/`fileprivate` function marked `@FTCommand` cannot actually be called from a
  different scenario file, so it is **not** listed as a command — instead the index reply carries
  a warning naming it. Drop the access modifier if it should be reusable from other scenario
  files, or drop `@FTCommand` if it's genuinely private to the file.
- Reports and run logs show the commands inside your helper, one step each — not the helper's
  name. A failure points at the inner command's line.
- The index lists your helpers; it doesn't run them. `ft_batch` (the MCP tool that executes DSL
  lines one at a time without saving a scenario) only understands built-in operation/scroll
  commands — a project command has to be written into the scenario `.swift` file, not batched.

### Link
- [index](../index.md)
