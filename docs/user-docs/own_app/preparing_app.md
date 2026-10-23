# Preparing the app under test

[in Japanese(日本語)](preparing_app_ja.md)

Register your own app with fleetest. Put it in a new test project, separate from `project1` for the sample app (SUT Store)
(registering it in `project1` overwrites the sample's registration).

## 1. Register the app

### Prompt for the AI

```text
Create a new fleetest test project named myshop and register my app in it.
The display name is "My Shop". The app ID is com.example.myshop on iOS and com.example.myshop.android on Android.
The source is in ~/src/myshop. Build it for the iOS Simulator and the Android Emulator and use those builds
(if it is a React Native app, build it in the Release configuration).
For devices, use Simulators / Emulators with the newest OS available on this Mac.
When you're done, tell me the names of the run profiles you created. There's no need to run any tests.
```

- Use the display name exactly as it appears under the icon on the home screen.
- If you already have builds, give their paths (`.app` / `.apk`) instead of the source.
- Name the test project (`myshop`) in your later prompts too.

Expected result:

- The AI assistant reports the run profile names (such as `ios-run`).
- In VSCode, switch to `myshop` with `fleetest: Select Project` in the Command Palette, and they appear in the **Profiles** tab of the device monitor.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Build the app first (the [Quick Start](../quick-start.md) has an `xcodebuild` example for the iOS Simulator;
build React Native apps in the Release configuration), then run these in the work folder.

```bash
../foundation-tester/.build/debug/fleetest project create myshop
../foundation-tester/.build/debug/fleetest profile setup --project myshop --platform ios --app-id com.example.myshop \
  --app-name "My Shop" --auto-device --app-path ~/builds/MyShop.app
../foundation-tester/.build/debug/fleetest profile setup --project myshop --platform android --app-id com.example.myshop.android \
  --app-name "My Shop" --auto-device --app-path ~/builds/myshop-debug.apk
```

</details>

## 2. When you rebuild the app

If the path is unchanged after you rebuild the app, you do not need to do anything (on every run, the app is reinstalled if it has changed).
Ask only when the path or file name changes.

### Prompt for the AI

```text
Change the iOS app path in the app profile of the fleetest test project myshop to ~/builds/MyShop-2.0.app.
```

Settable items:

- [Profiles](../reference/project/profiles.md)
- [Run profile settings](../reference/project/run_profile.md)

<br>

Next: [Preparing the servers your app depends on](preparing_server.md)

### Link
- [index](../index.md)
