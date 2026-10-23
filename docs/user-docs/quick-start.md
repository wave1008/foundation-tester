# Quick Start

[in Japanese(日本語)](quick-start_ja.md)

The shortest path from installing fleetest to creating scenarios for a sample app and running them.
You do not write scenarios by hand.

## 1. Environment

fleetest runs on a Mac with Apple silicon and macOS 26+. For details, see [Environment](overview/environments.md).

## 2. Before you start

Install the following.

- **Xcode 27.2+**
  - <https://apps.apple.com/app/xcode/id497799835>
  - After installing it, launch the Xcode app once and finish downloading its components.
- **Homebrew**
  - <https://brew.sh/>
- **VSCode**
  - <https://code.visualstudio.com/docs/setup/mac>
- **Android SDK (adb, Command-line Tools)** (if you test Android)
  - <https://developer.android.com/studio/install>
- **AI assistant (Claude Code, etc.)**
  - Install an AI assistant that supports MCP. Claude Code and Codex can be installed as VSCode extensions.

## 3. Installing fleetest

1. Create a **new, test-only folder** in Finder

2. Open the folder you created in VSCode

3. Start your AI assistant (the Claude Code extension, for example) and give it this instruction:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder, then set it up by
following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

4. If you use an **AI assistant other than Claude Code**, the setup asks whether to register the MCP server; choose to register it.

5. When the installation finishes, restart VSCode.

6. Click **fleetest mobile** in the status bar at the lower-left corner of VSCode. The device monitor opens.

   <img src="images/quick_start/en/device_monitor.png" width="640" alt="The device monitor just opened">

7. Give your AI assistant this instruction and confirm that no errors are reported

```text
Run ../foundation-tester/.build/debug/fleetest doctor and report the result.
```

## 4. Preparing the sample app

Prepare the sample app
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a Compose Multiplatform shopping app)
and declare its server to fleetest. The server is built with Kotlin (Ktor) and PostgreSQL.

### Prompt for the AI

```text
Clone https://github.com/wave1008/sut-ec-mobile next to this folder, then run bash ../sut-ec-mobile/fleetest/prepare.sh in this folder.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Run these in your work folder:

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git ../sut-ec-mobile
bash ../sut-ec-mobile/fleetest/prepare.sh
```

To use a different test project name, pass it like `bash ../sut-ec-mobile/fleetest/prepare.sh <name>`.

</details>

## 5. Prepare the profiles

Create the app profile and the run profile.

### Prompt for the AI

For iOS:

```text
In the fleetest test project project1, build the sut-ec-mobile iOS app and create its profiles. The app's display name is "SUT Store". Use two devices.
Use JDK 25 for the build (Homebrew's openjdk@25, at /opt/homebrew/opt/openjdk@25). Don't modify any shell configuration files.
```

For Android:

```text
In the fleetest test project project1, build the sut-ec-mobile Android app and create its profiles. The app's display name is "SUT Store". Use two devices.
Use JDK 25 for the build (Homebrew's openjdk@25, at /opt/homebrew/opt/openjdk@25). Don't modify any shell configuration files.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Build the app in the sut-ec-mobile folder. The build uses JDK 25 (prepare.sh in step 4 installs Homebrew's openjdk@25).

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@25

# iOS Simulator
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
#   -> build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
./gradlew :androidApp:assembleDebug
#   -> androidApp/build/outputs/apk/debug/androidApp-debug.apk
```

Go back to your work folder and run the following. The profiles are created in the test project project1 that step 4 created.

```bash
# iOS
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.sutec.mobile.ios --auto-device --count 2 --app-name "SUT Store" \
  --app-path ../sut-ec-mobile/build/ios-sim/Build/Products/Debug-iphonesimulator/iosApp.app

# Android
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.sutec.mobile.android --auto-device --count 2 --app-name "SUT Store" \
  --app-path ../sut-ec-mobile/androidApp/build/outputs/apk/debug/androidApp-debug.apk
```

Without `--app-name` the name defaults to the project name, which differs from the icon name on the home screen and produces a warning at the start of a run.
Passing the built app to `--app-path` makes the run install it on the device automatically.
`--auto-device` picks a Simulator/Emulator with the newest iOS runtime and the newest Pixel (and creates it
when missing; a missing iOS runtime is downloaded first: several GB, several minutes to tens of minutes;
one that is not running is started automatically at run time). The app profiles are named `ios-app` and `android-app`, and the
run profiles `ios-run` and `android-run`. `--count 2` makes the run profile hold two devices of that OS in total (existing devices with the same settings are reused in ascending number order and the missing ones are created; it is the same as "use two devices" in the instruction). You can also add devices later with "Add device" on the
"Profiles" tab of the VSCode extension's device monitor.

</details>
<br>

When it succeeds, the AI assistant reports the name of the run profile (such as `ios-run`), and that run profile is listed on the "Profiles" tab of the VSCode device monitor.

<img src="images/quick_start/en/profiles_tab.png" width="640" alt="The Profiles tab of the device monitor listing the run profile ios-run">

See [Profiles](./reference/project/profiles.md) for the details.

## 6. Create the scenarios

Let's create a happy-path test (the normal flow) up to opening a product.

### Prompt for the AI

```text
In the fleetest test project project1, create one "open-product-details test" for SUT Store on iOS. Name the file OpenProductDetails.swift.
It checks the happy path (the normal flow) of opening a product from the home screen until its product details are shown. Put the step that switches the app to English mode in setUpDevice.
Stop once you've told me the file name of the new scenario.
```

`setUpDevice` is where you put the preparation that is done once per device before the tests (here, switching the language).
For Android, read "on iOS" as "on Android".

The AI assistant launches the app on a device, reads the elements of the screens while
operating them, and turns that flow into a scenario.
Before it starts operating the app, the AI assistant starts the server declared in compose.yaml with `ft_services`.
The AI assistant asks for permission to use `ft_services` at this point; allow it.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Start the server by hand, create the test, and stop it when you are done.

```bash
../foundation-tester/.build/debug/fleetest services up --profile ios-run
../foundation-tester/.build/debug/fleetest services down --profile ios-run
```

</details>

## 7. Run it on a device

Let's run the scenarios you created.
On every run fleetest starts the server and stops it when the run ends. Services you started beforehand are taken over.

### Prompt for the AI

```text
Run the scenarios of the fleetest test project project1 on iOS (ios-run).
```

For scenarios created on Android, ask "on Android (android-run)" instead.
When asked for permission to use `ft_start_run`, which starts the run, allow it as well.

<img src="images/quick_start/en/run_in_progress.png" width="640" alt="The device monitor while the run is in progress">

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

`--profile` takes the name of the run profile from step 5 (`ios-run`, or `android-run` for Android).
The app, the devices, and the run-time settings are all resolved from it.

From VSCode, open the **Test Explorer**, pick the scenario, and click **Run**.
Before the first run, choose the run profile to use (for example `ios-run`) with `fleetest: Select Run Profile` in the
Command Palette. When the project has only one run profile, it is selected automatically on the first run.

</details>

## 8. Read the results

Every run writes a Markdown report per scenario to `TestProjects/<project>/reports/`.

<img src="images/quick_start/en/report.png" width="640" alt="A scenario report">

When a run fails, the server's log is kept at `TestProjects/<project>/results/runs/<month>/<runID>/services/server.log`.

Let's summarize the reports and analyze the errors.

### Prompt for the AI

```text
Summarize the latest run of the fleetest test project project1. If anything failed, use the report to find out why.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

Open the report in `reports/`. In VSCode, the Test Explorer shows pass/fail on each test, and you
can open the report from there.

</details>

## 9. Troubleshooting

If you run into a problem, ask your AI assistant. Common symptoms and how to narrow them down are
collected in [Troubleshooting](in_action/troubleshooting.md).

Next: [Asking the AI assistant](tutorial/asking_ai.md)

### Link
- [index](index.md)
