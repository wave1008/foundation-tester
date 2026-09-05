# installApp, removeApp, clearAppData

Installs, uninstalls, or resets the data of the app under test.

## Functions

| function | description |
|---|---|
| `installApp(path?)` | Installs the app (iOS: `.app`, Android: `.apk` or `.apks`). Without a path, the run profile's `appPath` is used (an explicit path always wins over the profile). |
| `removeApp(id?)` | Uninstalls the app. `id` defaults the same way as `launchApp()`'s `bundleID` when omitted. |
| `clearAppData(bundleID?)` | Keeps the app installed but clears its data and permissions, so onboarding and permission dialogs reappear. `bundleID` defaults the same way as `launchApp()`'s `bundleID`. |

## Example

```swift
installApp()                       // path from the run profile's appPath
installApp("/path/to/MyApp.app")
clearAppData()                     // back to a first-run state
removeApp()
```

## Notes

- **Reinstalling does not restore permissions.** On an iOS simulator, uninstalling and
  reinstalling an app leaves TCC permissions (location, etc.) granted, and the permission
  dialogs do not reappear. A scenario that assumes "reinstall = first-run state" will not see
  them — use `clearAppData()` instead.
- **`clearAppData()` also resets permissions** (iOS TCC / Android runtime permissions) back to
  not-granted, so permission dialogs appear again. This is the command to reach for when testing
  onboarding or first-run permission flows.
- `clearAppData()` is **iOS simulator only** — it fails on a physical device.
- `clearAppData()` clears `NSUserDefaults` / `SharedPreferences`, but **does not clear the
  Keychain (iOS) / Keystore (Android)**. If an app stores its "has been onboarded" flag there,
  first-run cannot be reproduced this way.
- **Removing the app under test breaks the rest of the run** — call `removeApp()` on your own
  test target only when you mean to end the scenario there.
- **On Android (physical devices and emulators alike), `adb install` verification (Play
  Protect's "Send app for a security check?") is turned off for the duration of the install and
  the device setting is restored afterwards.** The app under test is never sent to Google (with
  verification on, a release-signed APK leaves `adb install` blocked on that dialog — on an
  emulator with Google Play just the same).

### Link
- [index](../index.md)
