# Quick Start

The shortest path from a completed setup to creating test scenarios for a sample app and running
them. You do not write scenarios by hand. If you don't have a work folder with `TestProjects/`
yet, install Fleetest by following [Getting Started](getting-started.md) first.

> **With Codex**: do steps 1 and 2 in a session started with `codex --sandbox danger-full-access`.
> The default sandbox blocks cloning into the neighbouring folder and driving the Simulators. From
> step 3 on the default sandbox works (`ft_*` runs inside the MCP server). See
> [Other agents](reference/tools/other_agents.md) for registering the MCP server and setting its approvals.

## 1. Prepare the sample app

The app under test is [sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a sample
e-commerce shopping app (Compose Multiplatform, for both iOS and Android). Download it next to your
work folder and build it. The app fetches its products and images from a server, so start the
server as well.

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

A run needs two profiles — an app profile for the target app, and a run profile that lists the
devices to use. The app ID is `com.sutec.mobile` on both iOS and Android.

### Do it with the AI assistant

```text
Create the fleetest profiles for the sut-ec-mobile app (already built) that sits next to this folder.
1. Create the app profile and the run profile for each of iOS and Android with fleetest profile setup (do not write the JSON by hand)
2. Check with fleetest profile list that the app and the devices resolve
Values: the app's display name is SUT Store, the app ID is com.sutec.mobile on both iOS and Android, the app paths are the already-built .app (for the iOS Simulator) and .apk in sut-ec-mobile, and the device is picked automatically (--auto-device).
If no Simulator / Emulator is available, report it without creating one.
Done when: you report the names of the run profiles you created. Running tests is not needed.
```

The run profiles are named after the platforms (`ios` and `android`).

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Go back to your work folder and run:

```bash
# iOS
fleetest profile setup --platform ios --app-id com.sutec.mobile --auto-device \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
fleetest profile setup --platform android --app-id com.sutec.mobile --auto-device \
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

Either way, you get Swift files under `TestProjects/<project>/scenarios/`, with selectors taken
from the real screens. To read what was written, see
[Selector Expression](./reference/selector/selector_expression.md).

### Do it with the AI assistant

```text
Create exploratory tests for the login screen of sut-ec-mobile (SUT Store) only.
```

The AI assistant launches the app on a device, reads the elements of the login screen while
operating it, and turns the behavior it finds into test scenarios. To target a different screen,
replace the screen name. Saying which of iOS or Android to explore on makes it certain (for example
"... for the login screen of sut-ec-mobile (SUT Store) only, on Android.").

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Open the VSCode extension's device monitor and record in the Live Control tab. Operate the app
shown on screen, and what you did is generated as a scenario.

</details>

## 4. Verify without a device (dry-run)

Before touching a device, run a dry-run. It catches selector syntax errors, unreachable scenes,
and `expectation` blocks with no assertions, in a few seconds.

### Do it with the AI assistant

```text
Verify the scenarios you created with a dry-run
```

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
fleetest run --dry-run
```

</details>

## 5. Run it on a device

### Do it with the AI assistant

```text
Run the scenarios you created with the ios profile
```

For scenarios created on Android, name the `android` profile instead.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
# Clone layout (working inside the foundation-tester clone)
swift run fleetest run --profile ios

# External package layout (a separate work folder with TestProjects/)
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` takes the name of the run profile from step 2 (`ios`, as created by the command
above, or `android` for Android; if you passed `--run <name>`, use that name). The app, the devices, and the run-time
settings are all resolved from it.

From VSCode, open the **Test Explorer**, pick the scenario, and click **Run**.

</details>

## 6. Read the results

Every run writes a Markdown report per scenario to `TestProjects/<project>/reports/`, pass or
fail. It contains the result of each step with screenshots, and on failure the failure message,
the element list at the point of failure, and any self-healing suggestions.

### Do it with the AI assistant

```text
Summarize the results of that run. If anything failed, find the cause from the report
```

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Open the report in `reports/`. In VSCode, the Test Explorer shows pass/fail on each test, and you
can open the report from there.

</details>

## What to read next

How to ask for the same steps against your own app is covered in the [Tutorial](tutorial/asking_ai.md).

### Link
- [index](index.md)
