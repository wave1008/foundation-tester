# Update

[in Japanese(日本語)](update_ja.md)

The normal way to update fleetest is **from the VSCode extension's notification**. When a new release is out, the
extension tells you, and you update from the Settings tab of the device monitor. Asking the AI assistant or running
the update script in a terminal also works (see "Other ways" below).

An update brings in the **latest release** of fleetest.

## 1. Get the notification

When VSCode starts, the extension checks whether a new release exists (at most once a day). If there is one, a
notification appears at the bottom right.

```
fleetest X.Y.Z is available (current: A.B.C). You can apply it from the Settings tab of the device monitor.
[Open Settings tab] [What's new] [Skip this version]
```

- **What's new**: shows what changed in that release.
- **Skip this version**: stops notifying about that version (the next version is notified again).
- To check without waiting for the notification, run `fleetest: Check for Updates` from the Command Palette, or press
  "Check for updates" under "Updates" in the Settings tab.

## 2. Update from the Settings tab

Press "Open Settings tab" in the notification (or click **fleetest mobile** in the status bar and open the Settings tab).
The "Updates" section shows the current and the new version. Press "Update now".

```
Update fleetest? It runs git pull, rebuild, and extension reinstall, and takes a few minutes.
[Update]
```

After you press "Update", a progress notification "Updating fleetest" appears and the progress is written line by line
to the `fleetest` OUTPUT panel. It fetches fleetest, rebuilds it, reinstalls the VSCode extension and re-syncs the test
projects, all in one go. There is no way to cancel it (stopping halfway would leave a fetched but unbuilt state).

## 3. Reload the window

When it finishes, a confirmation appears.

```
The fleetest update is complete. Reload the window to apply it.
[Reload window]
```

Press "Reload window". **The replaced extension does not take effect until the reload** (if you did not press it, run
`Developer: Reload Window` from the Command Palette later).

If the update fails, you see "The fleetest update failed (exit code N)". Look for the `[fail]` line in the `fleetest`
OUTPUT panel. The log is also kept at `<work folder>/.fleetest/install-*.log`.

## 4. After updating

- **Restart the AI assistant**: the new version's instructions (skills) are read after a restart.
- **Bring runner machines to the same version**: if you use remote runners, update them to the same version as your Mac.
  Tests do not start while the versions differ (the extension checks before a run and offers "Update and run").
  See "After you update fleetest" in [Adding a Mac](fleet/adding_mac.md).

## Other ways

### Prompt for the AI

```text
Update fleetest to the latest version.
```

To only find out whether an update exists, ask "Is there a fleetest update?" (the clone is not changed).
The reload in step 3 is still needed afterwards.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

In the work folder (the one that contains `TestProjects/`), run the update script in the fleetest clone.
"Update now" in the extension runs this same script.

```bash
bash ../foundation-tester/Scripts/update.sh
```

- If there is nothing to update, it prints "Up to date" and exits without doing anything. Add `--force` only to
  reinstall a broken setup.
- If the clone is not `foundation-tester` next to the work folder, add `--tool-root <path to the clone>`; if the
  work folder is not the current directory, add `--work-dir <work folder>`.

</details>
<br>

## Updating on a closed network

Where the Mac cannot reach the Internet, run `bash <clone>/Scripts/update.sh` directly (the `curl` form cannot be used).
The setting that points GitHub to an internal mirror is in
[Network exposure and security](security/network_security.md).

### Link
- [index](index.md)
