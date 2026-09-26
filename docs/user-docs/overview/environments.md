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

Fleetest works without Apple Intelligence (Foundation Models), but enabling it unlocks two
things. If you enable it later, they just start working.

- **`screenLooksLike`** — visual verification of the screen against a natural-language
  description.
- **Occlusion guard** — the `requireVisible` check of `exist`, which keeps an element that is in
  the tree but covered by something else from passing as "visible".

(Self-healing does not use FM — see [Self-healing](../running/self_healing.md) — so it works the
same with or without Apple Intelligence.)

All of it runs on-device; screen data from your app never leaves your Mac.
**Apple's cloud (Private Cloud Compute) is never used.** Foundation Models also offers a
cloud-hosted model, but fleetest is pinned to the on-device one, and there is no setting that
switches to the cloud.

### Limitations

- **Experimental.** The on-device model covers the languages Apple Intelligence supports,
  Japanese included, and the Mac's system language can stay Japanese (confirmed on macOS 27.0).
  Accuracy against Japanese-language app UIs and Japanese `screenLooksLike` descriptions has not
  been measured yet.
- On macOS 26, `screenLooksLike` is unavailable, because image input requires macOS 27+. It is
  disabled automatically; everything else works without restriction. Text visual verification
  runs without its FM stage (see below).
- When FM is unavailable, `screenLooksLike` is **skipped**, not failed. Text visual verification
  judges from the on-device OCR reading (`ocrTextOcclusionCheck`) instead of FM and fails a step
  whose element OCR reads as not visible (the message says `judged by OCR alone`). Elements OCR
  cannot judge (nothing legible but something drawn) pass unverified, so confirm
  that FM actually works with `fleetest doctor --fm-only`, which performs one real inference on
  each of the text and vision paths and exits 1 when
  either is dead. Details in
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
