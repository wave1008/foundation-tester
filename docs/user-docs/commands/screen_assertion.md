# screenLooksLike

Visual screen check by Foundation Models: matches a screenshot against a description you write.

## Functions

| function | description |
|---|---|
| `screenLooksLike("description")` | Asks Foundation Models whether the current screen matches the description. Skipped (passes through) when the run profile has `screenLooksLike: false`. |

## Example

```swift
expectation {
    screenLooksLike("A login screen with email and password fields and a Log In button")
}
```

## Notes

- **Experimental.** The description can be written in Japanese too, but accuracy with Japanese
  descriptions has not been measured yet. See [environments.md](../overview/environments.md).
- Requires **macOS 27+** — on macOS 26 this check is automatically skipped. Check current
  availability with `fleetest doctor`.
- **Don't rely on it as a strict pass/fail gate.** The result depends heavily on the exact wording
  of the description (not on the language you write it in), and the same screen can flip between
  pass and fail depending on how the screenshot happens to be taken (though the result is
  deterministic for the same image). Use it only for rough, big-picture checks; for assertions
  that must not fail, write tree-based checks (`exist` / `textIs` / `countIs`) instead.
- Unlike Shirates(Classic)'s `screenIs`, there is no screen-nickname mechanism — you always
  describe what the screen should look like in the call itself.

### Link
- [index](../index.md)
