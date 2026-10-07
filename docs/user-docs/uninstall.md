# Uninstall

[in Japanese(日本語)](uninstall_ja.md)

How to uninstall Fleetest.

## Ask your AI assistant

Ask your AI assistant as follows, and it carries out the steps below for you.

```text
Uninstall fleetest by following ../foundation-tester/docs/user-docs/uninstall.md.
```

## 0. Runner machines (if you use them)

If you use remote runner machines, delete the work area on each runner machine before removing fleetest from your Mac:

```bash
../foundation-tester/.build/debug/fleetest remote teardown <machine>
```

If you created a signing keychain on a runner machine for physical iPhones, delete it on the runner machine too (it
holds your signing key):

```bash
security delete-keychain ~/Library/Keychains/fleetest-signing.keychain-db
```

## 1. VSCode extension

Uninstall it from VSCode's Extensions view, then run `Developer: Reload Window` to stop the
extension (while the extension is running, it restarts the fleetest processes you stop).

## 2. Stop the fleetest processes

This stops every fleetest process on this Mac, whichever work folder it belongs to (fleetest in your
other work folders stops too).

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 3. Work folder and clone

Quit VSCode, then delete the work folder and the fleetest clone (by default `foundation-tester`
next to your work folder; with its build folder it takes a few GB) via Finder or `rm`.
If `.build` reappears after you delete them, fleetest processes are still running (step 2).

## 4. Leftover files

- `~/.fleetest` (records of runs on this Mac and the like), `~/Library/Logs/fleetest` (logs), and `~/Library/Caches/fleetest`
- `~/.config/fleetest/` (settings and test data kept only on this Mac). **If you keep passwords or other secrets in
  `dataset/`, be sure to delete it**
- Virtual devices you created for fleetest, if you no longer need them — delete them from Xcode's
  "Devices and Simulators" or Android Studio's Device Manager

## 5. Your AI assistant's MCP registration

Claude Code's registration (`.mcp.json`) goes away with the work folder. If you registered the
server in your AI assistant's own settings, such as Codex, remove that registration too. For Codex:

```bash
codex mcp remove fleetest
```

### Link
- [index](index.md)
