# home, back, appSwitcher, tapAppIcon, rotateTo, fold, unfold, hinge

[in Japanese(日本語)](navigation_ja.md)

OS-level navigation: home screen, back, app switcher, home screen icon, screen rotation, and folding a foldable device.

## Functions

| function | description |
|---|---|
| `home()` | Goes to the home screen. |
| `back(settle:)` | Goes back to the previous screen (Android = back key / iOS = the navigation bar's back button, falling back to a left-edge swipe when there is none). |
| `appSwitcher()` | Opens the app switcher. On a home-button iPhone (e.g. iPhone SE) the switcher is a hardware double-press that cannot be sent, so the scenario is recorded as skipped (not applicable) from that step on instead of failing. |
| `tapAppIcon(name?)` | Finds and taps the app icon on the home screen. `name` defaults to the app profile's `appName` when omitted. |
| `rotateTo(.portrait, settle:)` / `rotateTo(.landscape, settle:)` | Rotates the app UI to that orientation. Only these two values exist. |
| `fold(waitSeconds:)` | Folds a foldable device to the outer screen and waits until the device reports it switched (up to `waitSeconds`, default = the run's default timeout). Fails if it does not switch. |
| `unfold(waitSeconds:)` | Unfolds to the inner (large) screen. Same rules as `fold`. |
| `hinge(_ degrees)` | Sets the hinge angle, 0 (folded) to 180 (unfolded); about 130 is the half-open book posture. Does not check which screen shows. |

## Example

```swift
launchApp()
tap("#settings")
back()                  // return to the previous screen
home()
tapAppIcon()             // find and tap the app icon by the app profile's name
appSwitcher()
rotateTo(.landscape)
rotateTo(.portrait)
fold()                  // foldable devices only
unfold()
hinge(130)              // half-open book posture
```

## Notes

- **`back(settle:)` reliability depends on the screen.** On iOS, a screen with a system navigation bar
  back button is deterministic; a screen with a framework's own navigation (e.g. a
  custom-drawn nav bar) falls back to an edge swipe, which only works if the screen supports
  interactive pop — do not call `back(settle:)` on a screen that cannot go back that way (use
  `tap()` on the app's own back button instead). On Android, if the soft keyboard is open,
  the first `back(settle:)` closes the keyboard instead of navigating (OS behavior) — call it twice
  when a field may still have focus.
- **`tapAppIcon` search order**: current screen first; if not found, Android opens the app
  drawer and scrolls (`flickCenterToTop`, up to 8 times), iOS pages through the home screens
  (`flickRightToLeft`, up to 5 times, stopping after two unchanged pages). Fails with
  `"App icon not found.(name)"` if never found. The icon is tapped only after its position is
  the same in two consecutive screen reads (a moving drawer or page swallows the tap). When the
  icon is your app's, the step then waits for the app to come to the foreground and fails (without
  tapping again) if it does not.
- **`tapAppIcon` never taps when the home-screen tree does not match the shown display.** Seen on the iPhone Duo simulator with Xcode 27.2 RC, where the inner display's layout leaks into the tree. On a simulator with two built-in displays it compares the tree's screen size with the shown display and fails with `the home screen tree reports a … screen but the shown display is …`; an icon whose centre is reported outside the screen is re-read for the screen wait timeout and then fails with `the home screen reports the icon outside the screen …` instead of tapping a point that cannot land.
- **`rotateTo` contracts on the app's UI orientation**, not on how the physical device is
  tilted — the frames a scenario reads are in app-space and behave the same across iOS,
  Android, and every supported UI framework. Only `.portrait` and `.landscape` exist (no
  left/right distinction).
- `rotateTo` waits until the orientation has actually changed before returning.
- **A scenario that rotates reverts to the original orientation automatically at the end**
  (Android also restores the auto-rotate setting).
- **The app must allow that orientation, or it will not rotate** (iOS
  `UISupportedInterfaceOrientations`, Android `screenOrientation`).
  On Android, when the app in front forbids that orientation, `rotateTo` fails right away and
  names the app's declaration.
- Android disables auto-rotate while rotating through this command, since the angle would not
  otherwise hold.
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

- **`fold` / `unfold` / `hinge` need a foldable device.**
  - iOS: the iPhone Duo **simulator** (Xcode 27.2+), sent through the XCUITest bridge, which both iOS modes support.
  - Android: a foldable **Emulator** (an AVD with a hinge sensor, e.g. Pixel 9 Pro Fold).
  - A physical iPhone can neither be folded nor have its fold state read, so the scenario is recorded as skipped (not applicable), with the reason `fold / unfold / hinge cannot drive a physical iPhone (fold it by hand); they run on the iPhone Duo simulator`.
  - On a physical Android device, a non-foldable model gets the not-applicable treatment below; a foldable model is not supported (fold by hand) and the step fails with that message.
- **On a non-foldable device the scenario is recorded as skipped (not applicable), not failed**, from that step on (same treatment as `appSwitcher()` on a home-button iPhone). The reason reads: `fold / unfold / hinge need a foldable device (the iPhone Duo simulator or a foldable Android Emulator)`.
- **The fold state is restored automatically at the end of the scenario** (like `rotateTo`'s orientation).
- **A foldable Android device shows a lock screen ("swipe up to continue") over the app when it is folded.** `fold()` dismisses it so the app is on the outer screen before the next step (the same unlock fleetest does before each scenario; a PIN or pattern lock cannot be dismissed).
- **`hinge` does not verify which screen shows.** On the iPhone Duo simulator the switch depends on the previous state (measured: opening switches between 120 and 150 degrees, closing between 20 and 10 degrees). On a foldable Android Emulator the posture follows angle ranges (Pixel 9 Pro Fold AVD: 0-30 closed, 30-150 half-opened, 150-180 opened). Use `fold()` / `unfold()` when the scenario needs a specific screen.
- **iOS mechanism**: Apple provides no public API to fold the simulator, so fleetest sends the same undocumented hinge event as Xcode's DeviceHub. A future Xcode may stop accepting it; `fold` / `unfold` verify the switch, so they would then fail loudly, never pass silently.

### Link
- [index](../../index.md)
