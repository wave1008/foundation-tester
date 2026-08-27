# Requirements

## Supported environment

| Target | Requirement |
|---|---|
| Common | macOS 26+ |
| If you test iOS | Xcode 26+, iOS simulator, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| If you test Android | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer |

You do not need both iOS and Android. Set up only the platform you actually test.

`fleetest doctor` checks what is available on this machine in one go — Foundation Models,
Xcode, xcodegen, simulators, and adb.

## Apple Intelligence (optional)

Fleetest works without Apple Intelligence (Foundation Models), but enabling it unlocks three
things. If you enable it later, they just start working.

- **Self-healing** — when a selector breaks, the model repairs it so the scenario can keep going.
  The fix is cached, so later runs don't call the model at all.
- **`screenLooksLike`** — visual verification of the screen against a natural-language
  description.
- **Failure triage** — a summary of the cause and a suggested fix, written into the report.

All of it runs on-device; screen data from your app never leaves your Mac.

### Limitations

- **English-only for now.** Apple's on-device model does not support Japanese during 2026;
  Japanese support is expected in 2027. To use it, **the Mac's system language must be English
  (United States)**, and `screenLooksLike` descriptions must be written in English. Behaviour
  against a Japanese-language app UI cannot be vouched for in the meantime.
- On macOS 26, only visual verification (`screenLooksLike` and the false-positive check) is
  unavailable, because image input requires macOS 27+. It is disabled automatically; everything
  else works without restriction.
- When FM is unavailable, these features are **skipped**, not failed. The run stays green with
  the features silently off, so confirm they actually work with `fleetest doctor --fm-only`,
  which performs one real inference. Details in
  [Troubleshooting](../in_action/troubleshooting.md).

## Supported UI frameworks

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |

### Link
- [index](../index.md)
