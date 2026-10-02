# Quick Start

The shortest path from a completed setup to creating test scenarios for a sample app and running
them. You do not write scenarios by hand.

## 1. Prepare the sample app

The app under test is [sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a sample
e-commerce shopping app (Compose Multiplatform, for both iOS and Android).

### Do it with the AI assistant

```text
Clone https://github.com/wave1008/sut-ec-mobile next to this folder, then:
1. Start the server (check until /health returns ok). Start it so that it keeps running after this session is closed (with nohup or similar)
2. Build the Android debug APK
3. Build for the iOS Simulator (arm64 only, unsigned)
Prerequisites: JDK 17 and Apple Container are required. If they are missing, you may install them with Homebrew.
Do not modify shell configuration files.
Done when: you report the paths of the build outputs. Installing and launching the app is not needed.
```

<details>
<summary><b>Do it manually (click to show details)</b></summary>

You need JDK 17 and Apple Container (`brew install container`).

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git
cd sut-ec-mobile
```

Leave the server running in another terminal:

```bash
./scripts/dev-server.sh    # http://localhost:8090
```

Then build the app:

```bash
# iOS Simulator (set the name in -destination to a Simulator you have)
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
#   -> build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
./gradlew :composeApp:assembleDebug
#   -> composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

See `server/README.md` in sut-ec-mobile for the details of starting the server.

</details>

## 2. Prepare the profiles

Create the app profile and the run profile.

### Do it with the AI assistant

```text
Create the fleetest profiles for the sut-ec-mobile app (already built) that sits next to this folder.
1. Create the app profile and the run profile for each of iOS and Android with fleetest profile setup (do not write the JSON by hand)
2. Check with fleetest profile list that the app and the devices resolve
Values: the app's display name is SUT Store, the app ID is com.sutec.mobile on both iOS and Android, the app paths are the already-built .app (for the iOS Simulator) and .apk in sut-ec-mobile, and the device is picked automatically (--auto-device).
If no Simulator / Emulator is available, you may create one.
Done when: you report the names of the run profiles you created. Running tests is not needed.
```

The run profiles are named after the platforms (`ios` and `android`).

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Go back to your work folder and run:

```bash
# iOS
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

Passing the built app to `--app-path` makes the run install it on the device automatically.
`--auto-device` picks an available Simulator/Emulator on this machine (one that is not running
is started automatically at run time). The run profiles are named after the platforms (`ios` and
`android`).

The setup creates no test project. The AI assistant creates `TestProjects/default/` first when it is missing;
by hand, run `fleetest project create default --platform <ios|android|both>` before the commands above
(the VSCode extension also creates it on startup after Reload Window).

</details>

See [Profiles](./reference/project/profiles.md) for the details.

## 3. Create the test scenarios

Let's create exploratory tests for the login screen.

### Do it with the AI assistant

```text
Create exploratory tests for the login screen of sut-ec-mobile (SUT Store) only.
```

The AI assistant launches the app on a device, reads the elements of the login screen while
operating it, and turns the behavior it finds into test scenarios.
Saying which of iOS or Android to explore on makes it certain (for example
"... for the login screen of sut-ec-mobile (SUT Store) only, on Android.").

## 4. Run it on a device

Let's run the test scenarios you created.

### Do it with the AI assistant

```text
Run the scenarios you created on iOS
```

For scenarios created on Android, ask "Run them on Android" instead.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` takes the name of the run profile from step 2 (`ios`, or `android` for Android).
The app, the devices, and the run-time settings are all resolved from it.

From VSCode, open the **Test Explorer**, pick the scenario, and click **Run**.

</details>

## 5. Read the results

Every run writes a Markdown report per scenario to `TestProjects/<project>/reports/`.

Let's summarize the reports and analyze the errors.

### Do it with the AI assistant

```text
Summarize the results of that run. If anything failed, find the cause from the report
```

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Open the report in `reports/`. In VSCode, the Test Explorer shows pass/fail on each test, and you
can open the report from there.

</details>

### Link
- [index](index.md)
