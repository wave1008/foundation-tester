# Requirements

## Supported environment

| Target | Requirement |
|---|---|
| Common | macOS 26+. Apple Intelligence (Foundation Models) is **optional** — it's used for self-healing, FM visual verification, and scenario generation. If you enable it later, it just starts working |
| iOS | Xcode 26+, iOS simulator, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Android (optional) | Android SDK (adb), emulator or physical device |
| Extension build | Node.js v24 or newer, npm v11 or newer (verified on v24 and v26) |

> On macOS 26, only FM's **visual verification** is unavailable (the image-input API requires
> macOS 27+). occlusion-guard (false-positive checking) and `screenLooksLike` are automatically
> disabled; everything else works without restriction.

Run `fleetest doctor` (or the `ft_doctor` MCP tool) at any time to check what's available on this
machine — Foundation Models availability, Xcode, xcodegen, simulators, and adb.

## What Apple Intelligence is used for

> **FM features are experimental, and English-only for now.** Apple's on-device model does not
> support Japanese during 2026; Japanese support is expected in 2027. Until then:
>
> - **The Mac's system language must be English** (United States). Under `ja-JP` the Apple
>   Intelligence pane does not even appear in System Settings and every FM call fails.
> - **Write `screenLooksLike` descriptions in English.**
> - Behaviour against a Japanese-language app UI is not something we can vouch for while the
>   model itself is English-only. The app under test is unaffected in every other respect — this
>   is a limit of the model, not of fleetest.
>
> **`availability` cannot be used to decide this.** With the system language set to Japanese,
> `SystemLanguageModel.default.availability` still reports `.available` while every call fails.
> Use `fleetest doctor --fm-only`, which performs a real inference and reflects it in the exit
> code. When FM is unavailable, self-healing, `screenLooksLike` and triage are skipped rather
> than failed — the run stays green with those features silently off, which is why the check
> matters.

Apple Intelligence (an on-device model) is optional, but three things depend on it when enabled:

- **Self-healing**: when a selector breaks, the model repairs it so the scenario can keep going
  (and the fix is cached, so replays after the first one don't need the model at all).
- **`screenLooksLike`**: multimodal visual verification against a natural-language description of
  the screen.
- **Failure triage**: when a scenario fails, the model helps summarize the cause and suggest a
  fix in the report.

None of this leaves the Mac — Foundation Models runs entirely on-device.

## Supported UI frameworks

Fleetest has been verified against apps built with:

| Framework | Platforms |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |

### Link
- [index](../index.md)
