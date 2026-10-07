# Adding physical devices

[in Japanese(日本語)](adding_physical_devices_ja.md)

These steps add a real iPhone or Android (a physical device) to your fleet so you can use it for tests. A physical
device joins the fleet as a device of the Mac it is connected to over USB. You can connect it to your own Mac or to a
runner machine (for the big picture, see [Fleet concepts](concepts.md)).

| Step | iOS | Android |
|---|---|---|
| 1. Prepare the Mac (once per Mac) | Signing settings, USB tunnel | adb is available |
| 2. Prepare the device (once per device) | Developer Mode, Auto-Lock | USB debugging, screen lock |
| 3. Prepare the app for the device | A signed build | Your usual APK |
| 4. Add it to a run profile | Same for both | Same for both |
| 5. Try it | Three approvals on the device the first time | — |

When you ask an AI assistant, name the connected device by its model (for example, "Register the iPhone 15 connected
over USB in the fleetest run profile ios-physical"). The AI assistant does not do the steps that need a person
(settings on the device, signing in to Xcode) for you.

## iOS

### 1. Prepare the Mac

👉 **Do this once on the Mac the device is connected to.**

1. **Install the USB tunnel**:
   ```bash
   brew install libimobiledevice
   ```
   Without it, fleetest talks to the device over Wi-Fi (LAN) even when it is connected over USB. Over LAN each round trip
   is about 10 times slower and the connection can drop midway. The bridge is also opened to the same LAN
   ([Network exposure and security](../in_action/network_security.md)).
2. **Sign in to Xcode with your Apple ID**: Xcode → Settings → Accounts. Installing the test bridge on the device
   needs a development signature.
3. **Set the Team ID and the bundle ID prefix** in `~/.config/fleetest/config.json`:
   ```json
   {
     "developmentTeam": "ABCDE12345",
     "bundleIDPrefix": "io.github.yourname"
   }
   ```
   - `developmentTeam` is your Apple Developer Team ID (10 characters). It is the OU of your signing certificate, which
     you can check with the command below. The value in parentheses from `security find-identity` is a certificate ID,
     not a Team ID.
     ```bash
     security find-certificate -c "Apple Development: <your name>" -p | openssl x509 -noout -subject
     ```
   - Set `bundleIDPrefix` to something no other team uses, such as your own domain or `io.github.<user name>`. With the
     default `com.example`, signing can fail because it collides with another team's App ID. Use the same value on every
     Mac of the same team.
   - The environment variables `FT_DEVELOPMENT_TEAM` / `FT_BUNDLE_ID_PREFIX` work too, and take precedence over the
     settings file.
   - Signing cannot be fixed in Xcode's Signing & Capabilities. fleetest overrides it with these values on every build.

### 2. Prepare the device

👉 **Do this once for each device.**

1. **Connect it to the Mac over USB and choose "Trust" at "Trust This Computer".**
2. **Turn on Developer Mode**: Settings → Privacy & Security → Developer Mode. The device restarts.
3. **Turn off Auto-Lock**: Settings → Display & Brightness → Auto-Lock → Never. fleetest cannot wake a device whose
   screen has gone dark. If the screen turns off during a step that waits a long time, later app launches are refused
   and the run stops.

### 3. Prepare the app for the device

A physical device needs a **build signed for devices** (an `.ipa` or an `.app`). A Simulator build does not install
(it fails with `The executable contains an invalid signature`).

Put the path of the device build in `appPathPhysical` in the app profile ("Package Path (Physical Device)" in the
VS Code extension). It sits next to `appPath`, which is for the Simulator ([Profiles](../reference/project/profiles.md)).

If your app has a server address built in, remember that `127.0.0.1` on the device is the device itself. To reach a
server running on your Mac, use a build with the Mac's LAN address built in.

## Android

### 1. Prepare the Mac

If you have the Android SDK (adb), nothing more is needed. Check that `adb devices` works.

### 2. Prepare the device

1. **Turn on USB debugging**: tap Settings → About phone → Build number seven times to show Developer options, then turn
   on Settings → System → Developer options → USB debugging (where these items are differs by model).
2. **Connect it to the Mac over USB. At "Allow USB debugging?", check "Always allow from this computer" and tap
   "Allow".**
3. **Check that `adb devices` shows the device as `device`** (`unauthorized` means step 2 is not done yet).
   ```
   List of devices attached
   R5CT1234ABC    device
   ```
4. **Set the screen lock to None**: a PIN or pattern lock cannot be cleared over adb. Make the screen timeout long
   enough too. fleetest turns the screen on and dismisses the lock screen before a run and before each scenario, but it
   cannot clear a PIN or pattern.

- fleetest changes some device settings to keep tests stable (animations off, no crash or ANR dialogs, and so on).
  **On a physical device these changes stay.** Revert them in Developer options if you need to.
- The Play Protect prompt ("Send app for a security check?") is avoided by turning the check off only while installing.
  The app is never sent to Google ([installApp](../reference/commands/install_app.md)).
- A device connected to adb over Wi-Fi works too, as long as `adb devices` lists it as `device`. Use the identifier it
  shows (such as `192.168.1.23:5555`) as is.

### 3. Prepare the app for the device

Use your usual APK as is. Release-signed APKs can be installed too.

## 4. Add it to a run profile

### In the VS Code extension

1. In the device monitor's "Profiles" tab, open the run profile and press "+" next to "Add devices".
2. The "Select Devices" list shows the **connected physical devices** (iOS shows "model / connection / UDID"). For a
   device connected to a runner machine, choose that machine in "Machine:" at the top.
3. Check the device and press "OK".

### By hand

Add the device to the run profile's `devices` with `"kind": "physical"` and its identifier.

```jsonc
{ "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 15", "kind": "physical",
      "udid": "00008130-000A1B2C3D4E5678" },
    { "platform": "android", "machine": "local", "name": "Galaxy S24", "kind": "physical",
      "serial": "R5CT1234ABC" } ] }
```

- **iOS `udid`** is the value of the form `00008130-…` in the details of `xcrun devicectl list devices`
  (`hardwareProperties.udid`). The Identifier column of the same list (of the form `XXXXXXXX-XXXX-…`) is a different
  value and does not work.
- **Android `serial`** is the left column of `adb devices`.
- `fleetest api installed-devices` also lists the connected physical devices and their identifiers
  (`ios.physicalDevices` / `android.physicalDevices`).
- `machine` is the machine name of the Mac the device is connected to (`"local"` for your own Mac).

## 5. Try it

```bash
fleetest run --profile <run profile> --scenario <scenario ID>
```

In the device monitor, a physical device's tile has a "Device" badge. You can also start only the bridge, without
running a test, with "Start bridge" in the tile's right-click menu.

### Approvals on iOS the first time

The first time the bridge starts, the device asks for the following in order. **Unlock the device and watch its screen**
while you approve them.

1. **Trust the developer certificate**: in Settings → General → VPN & Device Management, trust the developer app
   certificate. You need to do this again whenever the certificate is recreated.
2. **Allow UI automation**: while the bridge starts, a Touch ID / passcode prompt appears. Authenticate. If it stops
   with `Timed out while enabling automation mode` without showing the prompt, check that Settings → Developer → UI
   Automation is on, restart the device, and start again.
3. **Allow local network access**: if "Allow … to find devices on local networks?" appears, tap "Allow".

- **Right after the device is registered to your team, signing can fail once.** Start again and it goes through.
- With a free Personal Team, the signature expires after about 7 days. On a Mac you keep using, sign with an Apple
  Developer Program team.

## Connecting physical devices to a runner machine

A physical device connected to a runner machine works with the same steps. **Do steps 1 and 2 on the runner machine**
(sitting at it, or through screen sharing). On iOS, three more things are needed.

1. **Sign in to Xcode on the runner machine's screen.** This cannot be done over SSH. Put `developmentTeam` and
   `bundleIDPrefix` in the runner machine's `~/.config/fleetest/config.json` too.
2. **Run once from the runner machine's screen to register the device to your team.** Registration talks to Apple and
   cannot be done over SSH. Open a terminal on the runner machine through screen sharing and run a test that uses the
   device once (the first attempt may fail to sign; run it again and it goes through). Do this again when you switch to
   a different device.
   ```bash
   cd ~/fleetest-runner/users/<your issuerId>/work
   ~/fleetest-runner/foundation-tester/.build/debug/fleetest run --profile <run profile> --scenario <scenario ID>
   ```
   `issuerId` is the name you set in `~/.config/fleetest/config.json` on your Mac. If you have not set one, it is
   `<user name>@<host name>` of your Mac. You can also check with `ls ~/fleetest-runner/users/` on the runner machine.
3. **Keep the signing key in a keychain that works over SSH.** An SSH connection starts with the keychain locked, and
   unlocking it on the screen does not carry over. fleetest tries to unlock keychains with an empty password before
   building, so move the signing key to a dedicated keychain without a password and put it in the search list (run on
   the runner machine):
   1. In Keychain Access on the runner machine, select "Apple Development: <your name>" under "My Certificates" in the
      login keychain and save it as a `.p12` file with "Export" (give it a temporary password).
   2. In a terminal on the runner machine, create the dedicated keychain and import it:
      ```bash
      KC=~/Library/Keychains/fleetest-signing.keychain-db
      security create-keychain -p "" "$KC"
      security import ~/Desktop/dev.p12 -k "$KC" -P "<the password from step 1>" -T /usr/bin/codesign
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC"
      security set-keychain-settings "$KC"            # no arguments = never auto-lock
      security list-keychains -d user -s "$KC" ~/Library/Keychains/login.keychain-db
      rm ~/Desktop/dev.p12                            # delete the exported file
      ```
   Move only the development (Apple Development) signing identity. If your policy does not allow this, run tests that
   use the physical device from the runner machine's screen (screen sharing).

- To use an iPhone connected over Wi-Fi, the runner machine and the device must be on the same subnet, and the access
  point's client isolation (privacy separator) must be off. What matters is the runner machine's LAN, not your Mac.
- Install `brew install libimobiledevice` on runner machines that use physical devices too.

## What is different on physical devices

| Feature | Physical iPhone | Physical Android |
|---|---|---|
| Adding photos and videos (`addMedia`) | Not possible. Run on a Simulator, or put the file on the device by hand | Works |
| Clearing app data (`clearAppData`) | Done by reinstalling the app. Granted permissions are cleared too. Needs `appPathPhysical` | Works |
| Recording | A flip-book of screens taken around each operation (about 50 ms per capture) | Records normally |
| Engine | Always XCUITest (in-app cannot be used) | — |
| Device settings | Set Auto-Lock to Never | Set the screen lock to None. Settings fleetest changes stay |
| System alerts with no button to press | Can remain (it cannot restart SpringBoard as on a Simulator) | — |
| Reading elements inside Safari | Turn on Settings → Safari → Advanced → Web Inspector on the device | — |

## Troubleshooting

| Message / symptom | Cause and fix |
|---|---|
| `requires an Apple Developer Team ID` | `developmentTeam` is not set (iOS step 1, item 3) |
| `Cannot code-sign the bridge runner for a physical device` | Signing is not fully set up. The `Detected:` line that follows says what is missing (Xcode account, team, certificate, device registration and so on) |
| `No Account for Team` | Xcode has no account for the `developmentTeam` team. A mixed-up Team ID (the value in parentheses from `security find-identity`) also causes this |
| `the keychain holding the signing key is locked` | On a runner machine, the signing key cannot be used over SSH (item 3 of "Connecting physical devices to a runner machine") |
| `Developer Mode is off on the device` | Turn on Developer Mode (iOS step 2) |
| `Developer App Certificate is not trusted` | Trust the certificate in Settings → General → VPN & Device Management |
| `Timed out while enabling automation mode` | Unlock the device, authenticate at the prompt, and start again. If no prompt appears, check Settings → Developer → UI Automation and restart the device |
| `the iPhone is locked` | Unlock the device and set Auto-Lock to Never |
| `no physical iOS device with that UDID` | Check the USB connection, "Trust This Computer" and Developer Mode. Also check that `udid` is not the value from the Identifier column |
| `Failed to read socket ID from device` | App launches are stuck inside the device. Restart the device by hand |
| `The executable contains an invalid signature` | A Simulator build is being installed. Put a device build in `appPathPhysical` |
| `is not visible to adb` | Check the Android USB connection and the USB debugging approval. `adb devices` must show `device` |
| `could not unlock the lock screen` | Set the Android screen lock to None |
| `Connection to the driver was refused` (iPhone) | A drop midway, which happens more often over Wi-Fi (LAN). Install `brew install libimobiledevice` to use USB, and restart the bridge with `fleetest bridge down --port <port>` |

### Link
- [index](../index.md)
