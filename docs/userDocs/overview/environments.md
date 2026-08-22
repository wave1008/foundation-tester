# Requirements

## Supported environment

| Target | Requirement |
|---|---|
| Common | macOS 26+. Apple Intelligence (Foundation Models) is **optional** — it's used for self-healing, FM visual verification, and scenario generation. If you enable it later, it just starts working |
| iOS | Xcode 26+, iOS simulator, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Android (optional) | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24, npm v11 |

> On macOS 26, only FM's **visual verification** is unavailable (the image-input API requires
> macOS 27+). occlusion-guard (false-positive checking) and `screenLooksLike` are automatically
> disabled; everything else works without restriction.

Run `ftester doctor` (or the `ft_doctor` MCP tool) at any time to check what's available on this
machine — Foundation Models availability, Xcode, xcodegen, simulators, and adb.

## What Apple Intelligence is used for

Apple Intelligence (an on-device model) is optional, but three things depend on it when enabled:

- **Self-healing**: when a selector breaks, the model repairs it so the scenario can keep going
  (and the fix is cached, so replays after the first one don't need the model at all).
- **`screenLooksLike`**: multimodal visual verification against a natural-language description of
  the screen.
- **Failure triage**: when a scenario fails, the model helps summarize the cause and suggest a
  fix in the report.

None of this leaves the Mac — Foundation Models runs entirely on-device.

## Supported UI frameworks

Ftester has been verified against apps built with:

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |

### Link
- [index](../index.md)
