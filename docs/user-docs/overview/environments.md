# Environment

[in Japanese(日本語)](environments_ja.md)

## Supported environment

### What you prepare and install

| Target | Requirement |
|---|---|
| Machine and OS | A Mac with Apple silicon, macOS 26+ |
| Xcode | Xcode 26+ (<https://apps.apple.com/app/xcode/id497799835>) |
| Homebrew | Homebrew (<https://brew.sh/>) |
| VSCode | VSCode (<https://code.visualstudio.com/docs/setup/mac>) |
| Android SDK | Android SDK (adb, Command-line Tools) (<https://developer.android.com/studio/install>) |

### What is installed automatically

- xcodegen
- Node.js
- VSCode extension (fleetest mobile)
- iOS Simulator runtime and Simulator
- Android system image and Emulator

## UI frameworks verified to work

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |


## Features that use Foundation Models (macOS 27+)

On macOS 27+, enabling Apple Intelligence lets your tests use the features that rely on Foundation Models (FM).
To enable it, turn Siri on in System Settings → Siri.

### Limitations

- **Experimental.**
- When FM is unavailable, `screenLooksLike` is **skipped**, not failed.

Next: [Quick start](../quick-start.md)

### Link
- [index](../index.md)
