# Requirements

## Supported environment

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| If you test iOS | Xcode 26+, iOS Simulator, [xcodegen](https://github.com/yonaskolb/XcodeGen) |
| If you test Android | Android SDK (adb), Emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer |


## UI frameworks verified to work

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |


## Features that use Foundation Models (optional)

On macOS 27+, enabling Apple Intelligence lets your tests use the features that rely on Foundation Models (FM).

- **`screenLooksLike`**
  - Visual verification of the screen against a natural-language description.
- **Assisting text visibility checks**
  - Visually checks whether a text is actually displayed and not hidden behind something else, which makes test verdicts more accurate.

All processing is on-device; screen data from your app never leaves your Mac.
Apple's cloud, Private Cloud Compute (PCC), is never used.

### Limitations

- **Experimental.**
- FM features are not available on macOS 26.
- When FM is unavailable, `screenLooksLike` is **skipped**, not failed.

### Link
- [index](../index.md)
