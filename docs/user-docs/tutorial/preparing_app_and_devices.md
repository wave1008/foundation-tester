# Prepare the App and Devices

To run tests, you register with fleetest **what** to run (the target app) and **where** to run it (the devices).
The registration consists of two kinds of profiles.

| Profile | What it decides |
|---|---|
| App profile | The app's display name, app ID, and the path to the built app |
| Run profile | Which app to run, on which devices, and with what settings |

You can create both by asking an AI assistant. You do not need to write JSON by hand.

## First registration

### Do it with the AI assistant

```text
Create fleetest profiles for my app.
The display name is "My Shop". The app ID is com.example.myshop on iOS and com.example.myshop.android on Android.
The builds are ~/builds/MyShop.app (for the iOS Simulator) and ~/builds/myshop-debug.apk.
For devices, use Simulators / Emulators with the newest OS available on this Mac.
When you're done, tell me the names of the run profiles you created. There's no need to run any tests.
```

- Use the **display name** exactly as it appears under the icon on the home screen (do not add notes such as "(for testing)").
  fleetest looks for the home-screen icon by this name, and uses it to tell which app a system dialog belongs to.
- If you give the **path to the built app**, it is installed on the device automatically when tests run.
  Pass a `.app` for the iOS Simulator and an `.apk` for Android.
- For an app that exists only on iOS or only on Android, writing just one side is enough.

In Claude Code, `/fleetest-profiles` does the same thing (it asks you for the app name and so on, one by one).

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.example.myshop --auto-device \
  --app-path ~/builds/MyShop.app
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.example.myshop.android --auto-device \
  --app-path ~/builds/myshop-debug.apk
../foundation-tester/.build/debug/fleetest profile list
```

You can also create and edit them from the **Profiles** tab of the VSCode extension's device monitor.

</details>

## Add more devices

With more devices, tests are distributed to them automatically and the overall time gets shorter
(you do not need to rewrite any scenario).

### Do it with the AI assistant

```text
Add two more iPhone Simulators to the fleetest run profile ios-run.
If there aren't enough, you can create them with the same model and OS.
Then show me the profile's updated device list.
```

The number of devices that can run at once is limited by the Mac's memory and CPU. If adding devices makes things slower, ask to reduce them.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

In the **Profiles** tab of the VSCode extension's device monitor, use the run profile's "Add device" button,
or choose the devices to use with the checkboxes in the device list.

</details>

## Use physical devices (real iPhone / Android)

A physical device connected over USB can also be used for tests. **First turn off auto-lock on the device**
(iOS: Settings → Display & Brightness → Auto-Lock → Never. Android: Settings → Display → set Screen timeout long enough).
fleetest cannot wake a device whose screen has turned off.

### Do it with the AI assistant

```text
Register the iPhone connected over USB as a new fleetest run profile named ios-physical.
Use the app from the existing app profile; the build for physical devices is ~/builds/MyShop.ipa.
Then tell me the profile name and whether the device was recognized.
```

If several physical devices are connected, name the one you mean by its model ("Register the iPhone 15 connected over USB...").
Otherwise the AI assistant cannot decide which one to register and stops with a question.

An app for a physical iOS device must be signed (an `.ipa` or an `.app`).

## When you rebuild the app

If the app path is unchanged, you do not need to do anything. On every run, the app installed on the device is
compared with the app at the path, and it is reinstalled if they differ. Only when the path or file name changes do you
ask for the registration to be fixed.

```text
Change the iOS app path in the fleetest app profile to ~/builds/MyShop-2.0.app.
```

## More details

- List of settable items: [Profiles](../reference/project/profiles.md) and [Run profile settings](../reference/project/run_profile.md)
- To split test projects (the unit that groups tests): [Creating a test project](../reference/project/creating_project.md)

### Link
- [index](../index.md)
