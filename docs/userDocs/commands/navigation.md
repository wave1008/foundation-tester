# home, back, appSwitcher, tapAppIcon, rotateTo

OS-level navigation: home screen, back, app switcher, home screen icon, and screen rotation.

## Functions

| function | description |
|---|---|
| `home()` | Goes to the home screen. |
| `back()` | Goes back to the previous screen (Android = back key / iOS = the navigation bar's back button, falling back to a left-edge swipe when there is none). |
| `appSwitcher()` | Opens the app switcher. |
| `tapAppIcon(name?)` | Finds and taps the app icon on the home screen. `name` defaults to the app profile's `appName` when omitted. |
| `rotateTo(.portrait)` / `rotateTo(.landscape)` | Rotates the app UI to that orientation. Only these two values exist. |

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
```

## Notes

- **`back()` reliability depends on the screen.** On iOS, a screen with a system navigation bar
  back button is deterministic; a screen with a framework's own navigation (e.g. a
  custom-drawn nav bar) falls back to an edge swipe, which only works if the screen supports
  interactive pop — do not call `back()` on a screen that cannot go back that way (use
  `tap()` on the app's own back button instead). On Android, if the soft keyboard is open,
  the first `back()` closes the keyboard instead of navigating (OS behavior) — call it twice
  when a field may still have focus.
- **`tapAppIcon` search order**: current screen first; if not found, Android opens the app
  drawer and scrolls (`flickCenterToTop`, up to 8 times), iOS pages through the home screens
  (`flickRightToLeft`, up to 5 times, stopping after two unchanged pages). Fails with
  `"App icon not found.(name)"` if never found.
- **`rotateTo` contracts on the app's UI orientation**, not on how the physical device is
  tilted — the frames a scenario reads are in app-space and behave the same across iOS,
  Android, and every supported UI framework. Only `.portrait` and `.landscape` exist (no
  left/right distinction).
- `rotateTo` waits until the orientation has actually changed before returning.
- **A scenario that rotates reverts to the original orientation automatically at the end**
  (Android also restores the auto-rotate setting).
- **The app must allow that orientation, or it will not rotate** (iOS
  `UISupportedInterfaceOrientations`, Android `screenOrientation`).
- Android disables auto-rotate while rotating through this command, since the angle would not
  otherwise hold.

### Link
- [index](../index.md)
