# screenLooksLike

Visual screen check by Foundation Models: matches a screenshot against a description you write.

## Functions

| function | description |
|---|---|
| `screenLooksLike("description")` | Asks Foundation Models whether the current screen matches the description. Skipped (passes through) when the run profile has `fm: false` or `screenLooksLike: false`. |

## Example

```swift
expectation {
    screenLooksLike("A login screen with email and password fields and a Log In button")
}
```

## Notes

- Requires **macOS 27+** — on macOS 26 this check is automatically skipped. Check current
  availability with `ftester doctor`.
- Unlike Shirates(Classic)'s `screenIs`, there is no screen-nickname mechanism — you always
  describe what the screen should look like in the call itself.

### Link
- [index](../index.md)
