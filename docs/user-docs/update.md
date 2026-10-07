# Update

[in Japanese(日本語)](update_ja.md)

How to update fleetest.

When an update is available, the VSCode extension notifies you on startup (at most once a day).

## Ask your AI assistant

Ask your AI assistant to update fleetest.

> The log is kept in `<work folder>/.fleetest/install-*.log`.

## From VSCode

The device monitor's "Settings" tab is where you check and apply updates.

## Updating by hand

In your work folder (the one that holds `TestProjects/`), run the update script from the fleetest clone:

```bash
bash ../foundation-tester/Scripts/update.sh
```

- If there is no update, it prints "Up to date" and exits without doing anything. Add `--force` only to redo a broken install.
- If the clone is not the `foundation-tester` next to your work folder, add `--tool-root <path to the clone>`; if your work folder is not the
  current directory, add `--work-dir <work folder>`.
- It fetches fleetest itself, builds it, reinstalls the VSCode extension and re-aligns your test project, all in one go.

## After you update

- **Reload VSCode**: run `Developer: Reload Window` from the command palette. The extension is swapped for the new version only after
  the reload. Restart your AI assistant too, so it reads the new instructions.
- **Bring the runner machines to the same version**: if you use remote runs, update the runner machines to the same version as your Mac. Runs
  do not start while the versions differ. See "After you update fleetest" in [Adding a Mac](fleet/adding_mac.md).

## Updating on a closed network

Where the internet is not reachable, run `bash <clone>/Scripts/update.sh` directly (the form that fetches it with `curl`
does not work). The setting that redirects GitHub traffic to an internal mirror is in
[Network Exposure and Security](security/network_security.md).

### Link
- [index](index.md)
