# screenshot

Captures the current screen and embeds it in the report.

## Functions

| function | description |
|---|---|
| `screenshot(filename:?)` | Captures the current screen and embeds it in the report right after this step. Without a filename, a step-numbered name is used. Can also be called positionally, `screenshot("a.png")`. |

## Example

```swift
tap("#login_btn")
screenshot()               // step-numbered filename
screenshot("after_login.png")
```

## Notes

- The screenshot is embedded in the report immediately after the step that took it, so place
  the call right where you want the picture in the sequence.
- On Android, a **WebView screen can be missing from the device capture** (the underlying
  capture layer sometimes drops the WebView layer). When this happens, the tool detects the
  blank band and fills it in from a separate page image (CDP) instead — this is automatic and
  needs no scenario change, but it only kicks in when WebView debugging is enabled on the app
  (typically debug builds only). Because this loss is intermittent, do not rely on a screenshot
  to assert that a screen loaded — use `exist` / `notExist` on the element tree instead.

### Link
- [index](../index.md)
