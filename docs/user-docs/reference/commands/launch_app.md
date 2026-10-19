# launchApp, restartApp, terminateApp, openURL

[in Japanese(日本語)](launch_app_ja.md)

Starts, restarts, stops the app under test, or delivers a deep link URL to it.

## Functions

| function | description |
|---|---|
| `launchApp(appID?, url:)` | Terminates the app if running, then launches it fresh, starting at the entry screen. With `url:`, delivers that URL right after launch (see `openURL` below for delivery details). Delivery waits for the first screen to render (until a tappable element appears, up to the default wait), because frameworks such as React Native discard a URL that arrives before the screen is up; if none appears, the URL is delivered anyway with the note `launch-url-before-interactive-ui`. `appID` defaults to the default app (see Notes). |
| `openURL(url)` | Delivers a URL (deep link) to the already-running app without restarting it (warm delivery) — the transition is pushed on top of the current screen. Requires a custom URL scheme; Universal Links / App Links (`https://`) depend on AASA/assetlinks.json resolution and can fall through to Safari on a Simulator. |
| `restartApp(appID?)` | Terminates and launches again, resetting in-process state. `appID` defaults the same way as `launchApp()`. |
| `terminateApp()` | Terminates the app. |

## Example

```swift
launchApp()                                  // default app for this run
launchApp("com.example.myapp")
launchApp(url: "myapp://product/42")         // fresh process, then deliver the URL
openURL("myapp://cart")                      // deliver to the already-running app
restartApp()
terminateApp()
```

## Notes

- **`launchApp` always terminates first, even if the app is already running** — it never just
  brings the app to the foreground. Every call starts at the entry screen.
- **On iOS with the default (hybrid) engine, `launchApp` / `restartApp` of an app other than the scenario's own app
  fails in the middle of a scenario.** The in-app engine runs inside the app under test and cannot drive another app.
  Put the steps on another app (such as Settings) in a separate scenario under a run profile whose app profile names that app; that scenario runs on the XCUITest engine automatically.
- **Default app** (when `appID` is omitted, for `launchApp` / `restartApp` / `terminateApp` /
  `removeApp` / `clearAppData` / `appIs`): resolved from the run profile's `app`, then the app profile, then the current platform's `ios.app` /
  `android.app`. `@TestClass` has no `app:` argument (writing one is a compile error), so the same
  scenario targets each platform's own app when run with `--profile ios-run` and
  `--profile android-run`, without duplicating the class. Without a profile (`--port` / `--serial`),
  pass the app with `--app-id <bundleID>`.

  A project that tests several apps keeps each app's scenarios under a run profile for that app, or
  passes the bundle ID explicitly — `launchApp("<id>")` (also `restartApp("<id>")`,
  `clearAppData("<id>")`) — in the steps that switch to another app.
- **`openURL` does not restart the process** — that is the difference from `launchApp(url:)`,
  which restarts first and then delivers. Use `openURL` to test deep links arriving while the
  app is already open.
- On an iOS Simulator, the first `openURL` delivery for an app can trigger a one-time system
  confirmation alert ("Open in \"App Name\"?"); the hybrid and xcuitest engines dismiss it
  automatically. After that, consent for that device+app combination persists.
- `openURL` against an app that is not running lets the OS launch it, but that is not what the
  command is for. To verify opening from a URL when the app is not running, use `launchApp(url:)`.

### Link
- [index](../../index.md)
