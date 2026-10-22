# Preparing the app and devices

[in Japanese(日本語)](preparing_app_and_devices_ja.md)

Register your app and the devices to test on with fleetest.

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

What you'll see: the AI assistant reports the run profile names (such as `ios-run`). In VSCode, switch to `myshop` with
`fleetest: Select Project` in the Command Palette, and they appear in the **Profiles** tab of the device monitor.

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

## 2. Add more devices

### Prompt for the AI

```text
Add two more iPhone Simulators to the run profile ios-run in the fleetest test project myshop.
If there aren't enough, you can create them with the same model and OS.
Then show me the profile's updated device list.
```

If the Mac gets slow, ask to reduce them.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

In the **Profiles** tab of the device monitor, press the run profile's "Add device" button.

</details>

## 3. Use a physical device (optional)

Turn off auto-lock on the device first (fleetest cannot wake a device whose screen has turned off).

### Prompt for the AI

```text
Register the iPhone 15 connected over USB as a new run profile named ios-physical in the fleetest test project myshop.
Use the app from the existing app profile; the build for physical devices is ~/builds/MyShop.ipa.
Then tell me the profile name and whether the device was recognized.
```

Preparing the device itself (Developer Mode, USB debugging and so on) is covered in [Adding physical devices](../fleet/adding_physical_devices.md).

## When you rebuild the app

If the path is unchanged, you do not need to do anything (on every run, the app is reinstalled if it has changed). Ask only when the path changes.

```text
Change the iOS app path in the app profile of the fleetest test project myshop to ~/builds/MyShop-2.0.app.
```

Settable items: [Profiles](../reference/project/profiles.md) and [Run profile settings](../reference/project/run_profile.md)

Next: [Preparing the servers your app depends on](preparing_app_server.md)

### Link
- [index](../index.md)
