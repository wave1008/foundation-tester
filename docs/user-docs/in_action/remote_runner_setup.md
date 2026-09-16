# Setting Up a Remote Runner

These steps prepare another Mac (a runner machine) to run your tests. For what remote runs can do
and how they work, see [Remote Runners](remote_runners.md).

Most steps can be done either in the terminal (CLI) or in the VS Code extension. However,
**installing fleetest on the runner (Step 3) can only be done in the terminal**.

| Step | Where | CLI | VS Code extension |
|---|---|---|---|
| 0. Prepare the runner | Runner | — (by hand) | — |
| 1. Set up SSH key login | Your Mac | ✅ | — |
| 2. Register the machine | Your Mac | ✅ | ✅ |
| 3. Install fleetest on the runner | Your Mac | ✅ | — |
| 4. Add the runner's devices to your profiles | Your Mac | ✅ | ✅ |
| 5. Check the connection | Your Mac | ✅ | ✅ |
| 6. Run your first test | Your Mac | ✅ | ✅ |

In the examples below, the runner is `<user@192.168.xxx.xxx>` and its machine name is `M1Max`.

## Before you start

- **Your Mac**: fleetest is set up and you have a test project
  ([Getting Started](../getting-started.md)).
- **The runner**: it meets the following requirements. Step 0 takes care of anything missing.

| Requirement | Check (run on the runner) |
|---|---|
| Apple silicon Mac | `sysctl -n hw.optional.arm64` is `1` |
| Same Xcode version as your Mac (the macOS version may differ, as long as it runs that Xcode) | `xcodebuild -version` |
| Someone stays logged in at the console | `stat -f%Su /dev/console` matches the runner's user |
| System sleep disabled (display sleep and screen lock are fine) | `pmset -g \| grep " sleep"` |
| Remote Login on | checked in Step 1 |
| The firewall is off; if it is on, its "Block all incoming connections" is off | see item 2 of Step 0 |
| Homebrew is installed, in a version that supports that macOS | `brew --version` runs |
| Android SDK and AVDs (only when running Android) | `fleetest doctor` |

If your Mac and the runner run different macOS versions (for example 26 and 27), text visual
verification (OCR and FM) uses the features bundled with each Mac's macOS, so its results can
differ between Macs. If a check fails only on one Mac, suspect the macOS version difference.

## Step 0: Prepare the runner (on the runner, once)

Sit at the runner or use Screen Sharing. These tasks need sudo or the GUI, so fleetest does not
do them for you.

1. **Turn on Remote Login**: System Settings → General → Sharing → Remote Login.
2. **Check the firewall**. **If the firewall is off, there is nothing to do.** If it is on, turn
   off only "Block all incoming connections" (System Settings → Network → Firewall → Options).
   While that option is on, SSH is blocked too. The firewall itself can stay on. You can check the
   state with these commands:
   ```bash
   /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate   # "Firewall is disabled" means you are done
   /usr/libexec/ApplicationFirewall/socketfilterfw --getblockall      # "… set to disabled" means OK
   ```
3. **Turn on Screen Sharing** (recommended). It lets you log back in from your Mac after the
   runner restarts.
4. **Disable system sleep**:
   ```bash
   sudo pmset -a sleep 0
   ```
5. **Install Xcode and accept its license**. Use the same version as your Mac. You can
   download Xcode from <https://developer.apple.com/download/>.
   ```bash
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   ```
6. **Install Android Studio** (only when running Android). You can download Android Studio from
   <https://developer.android.com/studio>. Install the Android SDK in the setup wizard that runs
   the first time you start it.
   - Keep the SDK in its default location (`~/Library/Android/sdk`). fleetest runs over SSH, so an
     `ANDROID_HOME` set in `~/.zshrc` or similar is not read. In the default location, nothing
     needs to be configured.
   - You can create emulators (AVDs) in Android Studio's Device Manager. You can also create them
     from fleetest in Step 4.
7. **Install Homebrew**. In Step 3, fleetest uses Homebrew to install a tool it needs
   (xcodegen) automatically, so Homebrew is required.
   - **If Homebrew has never been installed**: run the following command in the terminal (the
     instructions are also at <https://brew.sh/>). It asks for the runner's login password partway
     through.
     ```bash
     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     ```
     When it finishes, it shows commands under "Next steps" that make `brew` available. Run them
     as shown, then check that `brew --version` works.
   - **If Homebrew is already installed**: check that `brew --version` works. On a Mac that has not
     been updated for a while, Homebrew may not support the newer macOS and may not run at all. In
     that case, update it with the command below (`brew update` itself does not run, so the update
     goes through git).
     ```bash
     git -C /opt/homebrew fetch origin && git -C /opt/homebrew reset --hard origin/master
     ```
8. **Stay logged in**. Do not log out. Locking the screen is fine.

If anything is still missing, `fleetest remote setup` in Step 3 lists it for you.

## Step 1: Set up SSH key login (on your Mac)

Run this in the terminal (if you get an error, ask an AI assistant: "Set up SSH so that I can connect to user@192.168.xxx.xxx"):

```bash
ssh-copy-id <user@192.168.xxx.xxx>                       # enter the password once, the first time only
ssh -o BatchMode=yes <user@192.168.xxx.xxx> 'echo ok'    # printing ok means you are ready
```

fleetest connects without entering a password, so the second line must succeed without one.
Also accept the host key here, the first time you connect.

For a runner behind a router, or one that uses a port other than 22, define an alias in
`~/.ssh/config` and use that alias as the destination (see "Runners on another network (across a
router)" in [Remote Runners](remote_runners.md)).

## Step 2: Register the machine (on your Mac)

Give the runner a name known only on this Mac (a machine name). The later steps and your profiles
refer to the runner by this name.

### Register with the CLI

```bash
fleetest remote machines add M1Max --host <user@192.168.xxx.xxx>
fleetest remote machines        # check the registration
```

- A machine name may contain only letters, digits, `_`, `.` and `-`. `local` means your own Mac,
  so it cannot be used.
- Running `add` again with the same name updates the registration.
- To remove it, run `fleetest remote machines remove M1Max`.

### Register in the VS Code extension

1. Run `fleetest: Show Device Monitor` from the Command Palette to open the Device Monitor.
2. Open the "Settings" tab and press "Add remote host" under the "Machines" table. A new row is
   added to the table.
3. Enter the SSH destination in "user@host" (for example `<user@192.168.xxx.xxx>`; an alias from
   `~/.ssh/config` also works).
4. Enter the machine name in "Machine (optional alias)" (for example `M1Max`). If you leave it
   blank, the destination without `user@` (for example `192.168.xxx.xxx`) becomes the machine name.
5. Normally, leave "Base directory" and "FM concurrency" blank. The base directory defaults to
   `~/fleetest-runner`. If you change it, do not point it at the place where the runner has its own
   copy of fleetest.
6. Press "Confirm" on the row. "Confirm" stays disabled until "user@host" is filled in, and
   nothing is registered until you press it.

- Editing a registered row saves the change right away.
- The button in the "Badge color" column opens a palette to choose the badge color. If you
  do not choose one, a color not used by other machines is assigned automatically. The color is
  used for the machine name badges in the Device Monitor.
- The "−" at the right end of a row removes the registration (there is no confirmation).
- If saving fails, the reason appears under the table as "Failed to save the machine registry".

The CLI and the extension read and write the same registry (`~/.config/fleetest/config.json`),
so either way gives the same result.

## Step 3: Install fleetest on the runner (on your Mac)

**This cannot be done from the VS Code extension.** Run the following command in the terminal.
You do not need to log in to the runner over SSH yourself.

```bash
fleetest remote setup M1Max --project <project>
```

- For `--project`, give the name of your local test project (`TestProjects/<name>`). If you have
  only one project, you can leave it out.
- The first time takes a few minutes because of the build.
- It is safe to run it again. If it stops partway, fix the problem and run the same command
  again; it picks up where it left off.

The command goes through these stages:

1. Checks that it can reach the runner and that someone is logged in.
2. Checks the runner's requirements. If anything still needs a person, it lists those items and
   stops.
3. Prepares fleetest and your test project under `~/fleetest-runner/` on the runner.
4. Brings the runner's fleetest to the same version as your Mac.

The exit code tells you how it ended:

| Exit code | Meaning | What to do next |
|---|---|---|
| `0` | Done | Go on to Step 4 |
| `2` | The required checks passed, but some items still need a person | Fix the listed items and run the same command again |
| `1` | Failed | Read the message and fix it (see "Troubleshooting" below) |

## Step 4: Add the runner's devices to your profiles (on your Mac)

Which devices run your tests is decided by the machine profile and the run profile. You edit
profiles on your Mac; they are sent to the runner automatically on every run. You never need to
edit files on the runner.

### Add them in the VS Code extension

1. In the Device Monitor's "Profiles" tab, open the machine profile that should hold the runner's
   devices.
2. Press the "+" next to "Add devices". "Select Devices" opens.
3. Choose `M1Max` in "Machine:" at the top. The list switches to the devices on the runner
   ("Loading..." is shown while it loads).
4. Check the devices you want to use. If the device you want does not exist, you can create it
   on the runner with the "+" next to "Create device". Before creating it, you are asked
   "This creates "<device name>" on M1Max. Continue?"; press "Create".
5. Press "OK". Devices with `"machine": "M1Max"` are added to the machine profile on your Mac.
6. Open the run profile and check the added devices under "Devices".

### Add them with the CLI

1. See which devices exist on the runner:
   ```bash
   fleetest remote exec M1Max -- api installed-devices
   ```
2. Write the devices, with `machine`, into the machine profile
   (`TestProjects/<project>/profiles/machines/<name>.json`):
   ```jsonc
   { "ios": { "devices": [
       { "machine": "M1Max", "name": "iPhone 17 Pro-01", "simulator": "iPhone 17 Pro", "udid": "<UDID>" } ] } }
   ```
3. Add them to the `devices` of the run profile (`TestProjects/<project>/profiles/runs/<name>.json`):
   ```jsonc
   { "devices": [ { "machine": "M1Max", "name": "iPhone 17 Pro-01" } ] }
   ```

### Things to keep in mind

- **Write `"machine": "local"` for devices on your own Mac**. Devices added in the extension get
  it automatically.
- You may mix devices on your Mac and on the runner in one run profile. The scenarios are divided
  among the machines according to how many devices each has, and they run at the same time.
- **Build the app on your Mac**. The app that the app profile's `appPath` points to is sent from
  your Mac to the runner automatically on every run. You do not need to build the app on the runner.

## Step 5: Check the connection (on your Mac)

### Check with the CLI

```bash
fleetest remote status --runner M1Max
```

```
HOST          REACHABLE  LOGIN  REV          TOOLCHAIN     RUNTIME             FM  BINARY  FREE
user@mac2     yes        yes    ✅ 9655a21…  ✅ Xcode26…   ✅ iOS 27.0: 24A434  -   yes     412 GB
```

| What you see | Meaning | What to do |
|---|---|---|
| `LOGIN` is `no` | The runner is sitting at the login window | Log in, for example over Screen Sharing |
| ⚠️ in `REV` or `TOOLCHAIN` | The version differs from your Mac | Run `fleetest remote setup M1Max` again. For an Xcode difference, install the same Xcode version on both Macs |
| ⚠️ in `RUNTIME` | The runner's iOS simulator runtime differs from your Mac's | Run `xcodebuild -downloadPlatform iOS` on the runner (this is only a warning; runs are not stopped) |
| `BINARY` is `no` | fleetest is not built on the runner | Run Step 3 again |

### Check in the VS Code extension

When you open the Device Monitor, the runner's devices appear as tiles just like your local ones,
with a badge showing the machine name.

- If a tile stays "unknown", the runner's fleetest is on a different version from your Mac, or
  the SSH connection is not working. Run Step 3 again, then press "Restart Monitor" in the toolbar.
- The toolbar graphs (MEM/CPU and so on) get one row per machine.

## Step 6: Run your first test (on your Mac)

The first run takes a few minutes to start, because the runner builds the scenarios and so on.
Later runs start within seconds. Reports, recordings and logs are brought back to your Mac.

### Run with the CLI

```bash
fleetest run --profile <run profile> --scenario <scenario id>
```

If the run profile's devices carry `"machine": "M1Max"`, the run goes to the runner without
`--runner`. To send just this one run to a different machine, add `--runner M1Max`.

**On Android, start the emulators first** (unlike iOS simulators, they do not start
automatically):

```bash
fleetest remote exec M1Max -- devices up --profile <run profile>
```

### Run in the VS Code extension

1. Run `fleetest: Select Run Profile` from the Command Palette and choose the run profile from
   Step 4.
2. Press "Run Tests" in the Device Monitor's toolbar. It starts the devices, then runs the tests.
   You can also run from the Test Explorer.

Before a run starts, the extension checks whether the runner's fleetest is on the same version as
your Mac.

- If it differs, you see "The remote runners' fleetest version differs from this machine's."
  Pressing "Update and run" brings the runner to your version and then runs.
- If it cannot be brought in line (your changes are not pushed, the runner cannot be reached,
  the Xcode versions differ, and so on), you see "Cannot run: the remote runners' fleetest cannot be
  updated from here." with the reason, and the run does not start.

## After you update fleetest

After updating fleetest on your Mac, bring the runner to the same version. Runs do not start
until the versions match.

- **CLI**: run `fleetest remote setup M1Max` again. To align the version only,
  `fleetest remote align M1Max` also works.
- **VS Code extension**: use "Update and run", which appears when you start a run.

## When several people share one runner

- On each person's Mac, set `issuerId` (your own name, for example `tanaka@dev-mbp`) in
  `~/.config/fleetest/config.json`. It also names your work area on the runner, so do not change
  it once set.
- **Each person runs `fleetest remote setup M1Max` once**. This creates their own work area on
  the runner.
- Only one person can run at a time. For how to wait and more, see "Sharing one runner between
  several people" in [Remote Runners](remote_runners.md).

## Troubleshooting

| Message or symptom | Cause | What to do |
|---|---|---|
| `cannot reach … over ssh` | Key login does not work, or the destination is wrong | Redo Step 1 |
| `must not contain ':'` | You wrote a port number in the destination (`host:2222`) | Define an alias in `~/.ssh/config` and use it as the destination |
| `remote setup` ends with exit code `2` | Some items on the runner still need a person | Fix the listed items and run the same command again |
| `neither xcodegen nor Homebrew is available` | Homebrew is not installed on the runner | Install Homebrew (item 7 of Step 0), then run `fleetest remote setup` again |
| `is sitting at the login window` | The runner is at the login window | Log in, for example over Screen Sharing |
| `git revision mismatch` | Your Mac and the runner are on different versions | Run `fleetest remote setup M1Max` again |
| `toolchain mismatch` | Xcode versions differ (the macOS version is not compared) | Install the same Xcode version on both Macs |
| `no runner workspace at …` | Your work area does not exist on the runner yet | Run `fleetest remote setup M1Max` once |
| `no running emulator for AVD …` | The Android emulator is not running | Run the `devices up` command from Step 6 |
| `app package not found at …` | There is no app at `appPath` on your Mac | Build the app on your Mac, or fix `appPath` |
| A tile stays "unknown" | The runner's fleetest is out of date, or SSH cannot connect | Run Step 3 again, then press "Restart Monitor" in the toolbar |

Messages not listed here are covered in the troubleshooting table at the end of
[docs/remote-runner-setup.md](../../remote-runner-setup.md) (Japanese only).

### Link
- [index](../index.md)
- [Remote Runners](remote_runners.md)
