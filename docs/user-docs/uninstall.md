# Uninstall

How to uninstall Fleetest.

## Ask your AI assistant

Ask your AI assistant as follows, and it carries out the steps below for you.

```text
Uninstall fleetest by following ../foundation-tester/docs/user-docs/uninstall.md.
```

## VSCode extension

Uninstall it from VSCode's Extensions view.

## Work folder

Quit VSCode, then delete it via Finder or `rm`.

## Leftover files and processes

After stopping the fleetest processes (commands below), also delete the following.

- The fleetest clone (by default `foundation-tester` next to your work folder; with its build folder it takes a few GB)
- `~/.fleetest` (records of runs on this Mac and the like) and `~/Library/Logs/fleetest` (logs)
- Optionally `~/.config/fleetest/config.json`
- Virtual devices you created for fleetest, if you no longer need them — delete them from Xcode's
  "Devices and Simulators" or Android Studio's Device Manager

If `.build` reappears after you delete the work folder, fleetest processes are still running.

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

### Link
- [index](index.md)
