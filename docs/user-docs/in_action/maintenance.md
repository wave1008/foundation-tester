# Maintenance for long-term use

As you keep using fleetest, some things pile up on disk and some tasks come up when you update macOS or
Xcode. fleetest handles most of it automatically. This page lists what is handled for you and what you
need to do yourself.

## Handled automatically

You don't need to do anything for these.

| What | What happens | Details |
|---|---|---|
| Recordings, reports, logs, bridge diagnostic logs | After a test run finishes, any category above 90% of its limit is trimmed in the background, oldest first | "Cleaning Up Logs and Recordings" in [VSCode extension](../tools/vscode_extension.md) |
| iOS Simulator wallpaper cache, diagnostic logs, and the News widget's saved items | Removed right before fleetest boots a Simulator (only Simulators that are stopped) | "iOS Simulator wallpaper cache (CLI only)" in [VSCode extension](../tools/vscode_extension.md) |
| Android emulator data | At the start of a test run, the emulator gets a Wipe Data if its data is over the threshold (8 GB by default). It also gets a Wipe Data, followed by one more install attempt, when installing the app fails because the device is out of storage | `wipeDataOnBloat` in [Run profile settings](../project/run_profile.md) |
| Bridges on the devices | When the fleetest version changes, they are reinstalled or rebuilt the next time they are used | — |
| Bridges that stop responding | When the extension detects one, it tries to repair it while no test is running (setting `fleetest.autoRepairBridge`, on by default) | — |
| Update checks | The extension checks once a day and notifies you (it never pulls anything by itself) | "Updating Fleetest" in [Getting started](../getting-started.md) |

The Simulator cleanup only runs when fleetest boots the Simulator (not when you boot it from Xcode or
Simulator.app). A Simulator that stays booted is cleaned the next time fleetest boots it again.

## Things you do yourself

### When you update fleetest

When you get an update notice, follow "Updating Fleetest" in [Getting started](../getting-started.md).

If you use remote runner machines, bring them to the same version as this Mac. Test runs don't start
while the versions differ. See "After you update fleetest" in
[Setting up a remote runner](remote_runner_setup.md).

### When you update macOS or Xcode

- **If you use a macOS beta, move Xcode to the same beta whenever you update macOS.** Otherwise the
  fleetest programs crash with a dyld error right after they start. When that error
  (`dyld[…]: Symbol not found` / `Library not loaded`) appears, the VSCode extension and the install and
  update scripts spot it and show the fix below.
- After Xcode matches, rebuild everything. `<TOOL_ROOT>` is the fleetest clone (by default
  `foundation-tester` next to your work folder).

  ```bash
  rm -rf <TOOL_ROOT>/.build <work-folder>/.build
  bash <TOOL_ROOT>/Scripts/update.sh --force
  ```

  The rebuild takes a few minutes.

- If, after updating Xcode, you are told the iOS Simulator runtime is missing, install it with
  `xcodebuild -downloadPlatform iOS`.

### When FM (Foundation Models) stops working

If a test run ends with `FM is dead on this machine`, the on-device model (FM) on this Mac has stopped
working. You can check with `fleetest doctor --fm-only` (it exits with code 1 when FM is not working).

- **Once FM stops, it does not come back until you restart the Mac.** Restart the Mac while no test is running.
- Tests still run in the meantime, but `screenLooksLike` is skipped, and the text visual verification is
  judged by OCR alone. **Text that OCR cannot judge passes without being checked** (such steps carry the
  note `visibility-guard-skipped`).
- While FM is known to have stopped, fleetest does not call it (calling a stopped FM takes more than ten
  seconds each time). It checks again once every two minutes, so it is used again as soon as it comes back.

### Keeping disk space free

- **Recordings, reports, and logs**: These are deleted automatically. To free space right away, use
  "Clean up now" on the extension's Settings tab, or run `fleetest clean` in a terminal (add `--dry-run`
  to see the amount without deleting anything).
- **Bridge diagnostic logs**: If a bridge keeps running, for example while you stream a physical device's
  screen or keep an MCP session going, the log grows by a few GB per device per day. While the VSCode
  extension is open, a bridge that goes over the limit is rebuilt automatically, as long as no test, MCP
  session, or live control is using it (that device's screen pauses for tens of seconds meanwhile). If you
  use fleetest without the extension, stop the bridges you are not using when the log goes over the limit
  (`fleetest bridge down --port <port>`).
- **Wallpaper cache of stopped Simulators**: `fleetest clean --simulator-poster-cache` clears it for every
  stopped Simulator at once.
- **The virtual devices themselves**: To reset a device that has grown too large, right-click it in a run profile's section
  on the Device Monitor's Profiles tab and choose "Wipe Data". All installed apps, settings, and saved data are
  removed, and this can't be undone. If your app isn't installed automatically, install it again
  afterwards. To see how much space each virtual device uses, press "Refresh storage" under
  "Device health" in the Results Dashboard.
- **What stays**: The result records (the pass/fail and timing JSON) are never deleted, but even
  thousands of runs take only a few tens of MB. The build folder (`.build`) takes a few GB, but it does
  not keep growing. If you delete it, it is rebuilt the next time you use fleetest, which takes a few
  minutes.

### Remote runner machines

Nobody looks at a runner machine's results, reports, and recordings the way you look at your own, so
they pile up unnoticed. Run `fleetest remote clean <machine>` from time to time. You can check the free
space with `fleetest remote status`. `remote clean` stops if a test is running.

### Image samples

The image samples you use with `findImage` and the like look different on each OS version. When you
update the OS of a device you test on, add samples taken on the new OS
([Finding by image](../commands/find_image.md)).

### Self-healing suggestions

If you use self-healing, review the fix suggestions that appear after a test run and apply them
([Self-healing](../running/self_healing.md)). fleetest never rewrites your scenario source by itself, so
the same suggestions keep appearing on every run until you apply them.

### Link
- [index](../index.md)
