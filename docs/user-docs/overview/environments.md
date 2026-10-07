# Environment

[in Japanese(日本語)](environments_ja.md)

## Supported environment

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| If you test iOS | Xcode 26+, iOS Simulator, [xcodegen](https://github.com/yonaskolb/XcodeGen) |
| If you test Android | Android SDK (adb), Emulator or physical device |
| Installing the VSCode extension | VSCode, Node.js v24 or newer, npm v11 or newer (to build and install the extension) |


## UI frameworks verified to work

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |


## Features that use Foundation Models (optional)

On an Apple silicon Mac with macOS 27+, enabling Apple Intelligence lets your tests use the features that rely on Foundation Models (FM).
To enable it, on macOS 27, turn Siri on in System Settings → Siri (Siri uses Apple Intelligence); on macOS 26, turn on "Apple Intelligence" in System Settings → Apple Intelligence & Siri.

- **`screenLooksLike`**
  - Visual verification of the screen against a natural-language description.
- **Text visual verification**
  - Visually checks whether a text is actually displayed and not hidden behind something else, which makes test verdicts more accurate.

All processing for these features is on-device; screen data from your app never leaves your Mac through them (the screen contents sent to your AI assistant when you create tests are a separate matter).
Apple's cloud, Private Cloud Compute (PCC), is never used.

### Limitations

- **Experimental.**
- FM features are not available on macOS 26.
- When FM is unavailable, `screenLooksLike` is **skipped**, not failed.

Next: [Getting Started (Installation)](../getting-started.md)

### Link
- [index](../index.md)
