# launchApp, restartApp, terminateApp, openURL

Starts, restarts, stops the app under test, or delivers a deep link URL to it.

## Functions

| function | description |
|---|---|
| `launchApp(bundleID?, url:?)` | Terminates the app if running, then launches it fresh, starting at the entry screen. With `url:`, delivers that URL right after launch (see `openURL` below for delivery details). `bundleID` defaults to the default app (see Notes). |
| `openURL(url)` | Delivers a URL (deep link) to the already-running app without restarting it (warm delivery) — the transition is pushed on top of the current screen. Requires a custom URL scheme; Universal Links / App Links (`https://`) depend on AASA/assetlinks.json resolution and can fall through to Safari on a simulator. |
| `restartApp(bundleID?)` | Terminates and launches again, resetting in-process state. `bundleID` defaults the same way as `launchApp()`. |
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
- **Default app** (when `bundleID` is omitted, for `launchApp` / `restartApp` / `terminateApp` /
  `removeApp` / `clearAppData` / `appIs`): resolved in this order —
  1. `@TestClass(app: "...")` on the scenario, if present — this always wins.
  2. The run profile's `app`, then the app profile, then the current platform's `ios.app` /
     `android.app`.

  Normally you do not write `app:` at all: the same scenario then targets each platform's own
  app when run with `--profile ios` and `--profile android`, without duplicating the class.
  Write `app:` only when a project mixes scenarios for more than one app and a scenario needs to
  pin its target explicitly.
- **`openURL` does not restart the process** — that is the difference from `launchApp(url:)`,
  which restarts first and then delivers. Use `openURL` to test deep links arriving while the
  app is already open.
- On an iOS simulator, the first `openURL` delivery for an app can trigger a one-time system
  confirmation alert ("Open in \"App Name\"?"); the hybrid and xcuitest engines dismiss it
  automatically. After that, consent for that device+app combination persists.
- `openURL` against an app that is not running lets the OS launch it, but that is not what the
  command is for — cold-start behavior itself cannot be exercised through the in-app engine.

### Link
- [index](../index.md)
