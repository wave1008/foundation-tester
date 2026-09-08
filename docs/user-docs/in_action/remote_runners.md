# Remote Runners

`fleetest run --runner <runner>` dispatches a run to another Mac over SSH, runs it there exactly as a
local run, and brings the output and artifacts back. This page summarizes what it can do and how
to set it up; the full step-by-step is [docs/remote-runner-setup.md](../../remote-runner-setup.md)
(not duplicated here).

## What it can do

| | |
|---|---|
| Dispatch a job to one remote host (CLI and VS Code extension) | ✅ |
| Progress display, cancellation, timeout | ✅ |
| Collect reports, JUnit, recordings, run logs | ✅ |
| Provision a runner from your machine in one command (`remote setup`); remove one the same way (`remote teardown`) | ✅ |
| Batch status/cleanup across hosts (`remote status` / `remote clean`) | ✅ |
| One-off remote command (`remote exec`) | ✅ |
| Simultaneous dispatch to multiple hosts (a fleet, `run --fleet`) | ✅ |
| Split one scenario set across hosts (`run --fleet <name> --split`) | ✅ |
| Remote results feeding into `fleetest results` (flaky detection etc.) | ✅ (collected by default) |
| Remote device tiles in the Device Monitor (state, live video) | ✅ |

Scenarios and profiles are transferred automatically on every run, so editing always happens on
your machine — the runner machine is never edited directly.

## Overview

```
Issuing Mac (yours)                     Runner machine
fleetest run --runner mac2 …             ~/fleetest-runner/               ← dedicated base directory
  ├ compatibility check (rev, Xcode) ssh ├── foundation-tester/          ← the tool's clone (fixed name, shared)
  ├ transfer (rsync: scenarios/config) ─> └── users/<issuerId>/work/     ← your work area (per issuer)
  ├ display output                             ├── TestProjects/<project>/
  └ collect artifacts <──────────────────      └── .build/
```

The runner's *own* foundation-tester clone (if it has one for itself) is never touched — the
remote runner is entirely self-contained under `~/fleetest-runner/`.

## Runner machine prerequisites

| Requirement | Check |
|---|---|
| Apple silicon Mac | `sysctl -n hw.optional.arm64` is `1` |
| Same Xcode and macOS as the issuing machine | `xcodebuild -version` |
| Logged into the console (an active GUI session) | `stat -f%Su /dev/console` matches the runner's user |
| System sleep disabled (display sleep / screen lock are fine) | `pmset -g \| grep " sleep"` |
| Remote Login on, key-based SSH access | see Step 1 below |
| Firewall's "Block all incoming connections" is off (it blocks sshd too; the firewall itself may stay on) | `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getblockall` reports `disabled` |
| Homebrew recent enough to know this macOS | `brew --version` runs |
| Git can reach GitHub directly (no stale proxy config) | `git config --global --get-regexp '^https?\.'` is empty |
| Android SDK and AVDs (only if running Android) | `fleetest doctor` |
| English system language + Apple Intelligence enabled (only for `screenLooksLike`/self-healing) | `fleetest doctor --fm-only` |

## Setup flow

1. **Step 0 (on the runner, once, manual)** — enable Remote Login and (recommended) Screen
   Sharing, disable system sleep, install Xcode and accept its license, make sure Homebrew is
   current, check for stale git proxy settings, stay logged in.
2. **Step 1 (issuing machine) — enable key-based SSH** (`ssh-copy-id`, then confirm
   `ssh -o BatchMode=yes` succeeds).
3. **Step 2 (issuing machine) — provision the runner in one command**:
   `fleetest remote setup <user>@<host> --project <project>`.
4. **Step 3 — align versions.** Dispatch refuses to run unless the git commit and the Xcode/macOS
   fingerprint match; `remote setup`'s align step keeps them in sync.
5. **Step 4 — machine name and profile.** A run profile resolves its device set through a machine
   profile.
6. **Step 5 — check connectivity**: `fleetest remote status --runner <user>@<host>`.
7. **Step 6 — first dispatch**: `fleetest run --runner <user>@<host> --profile <run profile>
   --scenario <id>` (the first dispatch takes a few minutes; later ones start in seconds).

**`/fleetest:fleetest-remote-setup` delegates the machine work to `fleetest remote setup`** — it
asks what it needs to know, hands off anything that requires a human, and reports the result;
it does not perform Step 0's manual, sudo/GUI-requiring items itself.

## Runners on another network (across a router)

A runner **does not have to be on the same LAN**. Any Mac you can reach with
`ssh <target> 'echo ok'` can take dispatches. Only whole jobs are remoted, so the setup
tolerates round-trip latency reasonably well.

- **The only port you open is SSH, from the issuing machine to the runner.** Nothing listens on
  the issuing machine — transfers, progress, artifact collection and live video all travel inside
  that one connection.
- **Put ports and jump hosts in `~/.ssh/config`.** A target cannot carry a port (`host:2222`);
  targets containing `:` or whitespace are rejected. Define an alias with `Host mac2` /
  `HostName` / `Port` / `ProxyJump` and use that alias as the target.
- **Do not expose the SSH port to the open internet.** The intended shape is a VPN link
  (Tailscale or similar). If you must forward a port, forward exactly one, restrict it to the
  issuing machine's address, and disable password authentication on the runner's sshd.
- **Screen Sharing (5900) does not belong on the router.** Tunnel it instead:
  `ssh -L 5900:localhost:5900 <target>`, then connect to `vnc://localhost:5900`.
- **A thin link degrades rather than breaks** — live video falls back to still images when the
  stream cannot be established, and a tile goes `unknown` while the link is down ("not observed",
  which is not the same as "free"). The expensive part to collect is screen recordings.

**Physical devices attached to the runner** are a matter of the runner's own LAN, unrelated to the
route from your machine. Over USB nothing needs configuring. A LAN-attached iPhone listens while
the Mac connects out, so no firewall change is needed on the Mac — but the runner and the device
must be on the same subnet, and the access point's client isolation must be off.

## Terms: machine (alias) and host (host name / IP)

- **host** = a host name or IP address (`user@192.168.20.101` and the like — the real address)
- **machine** = a **local alias for that host**, private to this Mac. It is the name you type in the
  "Machine" column of the Settings tab, and the name profiles refer to

Aliases can be renamed at any time. **So that renaming stays harmless, records (result JSON and the
like) keep the host name, and neither the files sent to a runner nor its arguments carry the alias.**

## Machine profiles decide the machine

A device's machine profile can carry `machine`, naming a registered machine:

```jsonc
// profiles/machines/M1Max.json
{ "machine": "M1Max",
  "ios": { "devices": [ { "machine": "M1Max", "name": "simulator1", "simulator": "iPhone 17 Pro" } ] } }
```

A run profile picks its machine profile by name, so **selecting a run profile also selects
which machine it runs on** — no separate `--runner` is needed for normal use. Local devices should
write `"machine": "local"` explicitly (omitting it means "inherit the profile's default", which
matters once a profile mixes local and remote devices). `--runner <name>` on the command line
overrides the profile, naming either a registered machine or a raw host / IP directly. **Profiles
written with the old key `"host"` are still read** (renamed to `machine` on 2026-08-26).

## `run --runner` and `--fleet`

```bash
fleetest run --runner <name> --profile <run profile>            # send this one run to a specific machine
fleetest run --project <project> --fleet <name>                 # run the same scenarios on every host in the fleet
fleetest run --project <project> --fleet <name> --split          # split scenarios across the fleet's hosts instead
```

A fleet is defined in `TestProjects/<project>/profiles/fleets/<name>.json`, listing `host`/
`profile` pairs (`"local"` for the issuing machine itself, or a registered host name). `--split`
distributes scenarios across hosts by estimated duration instead of duplicating the whole set.
`--junit <path>` merges every host's results into one file, with each host's `<testsuite>`
carrying its `hostname`.

## Using it from the VS Code extension

There is no "choose a target host" UI — selecting a run profile *is* selecting the host, through
its machine profile's `host`. The extension's involvement is:

- **Register hosts** in the Device Monitor's Settings tab (name / host / base directory) — this
  writes to the same host registry the CLI uses (`~/.config/fleetest/config.json`).
- **Add hosts and devices in a machine profile's edit dialog** — choosing a host there switches
  the device list to what actually exists on that machine, and a device can be created there
  directly.

Once registered, remote device tiles behave like local ones in the Device Monitor — status,
live streaming, and per-tile start/stop all work the same way, with a host-name badge as the only
visible difference. Automatic bridge/health repair, however, only applies to local devices.

## Sharing one runner between several people

Only **one run at a time** can go to the same runner (its devices belong to that machine, so two
runs must not fight over the same simulator). When it is busy, fleetest prints who has been
holding it and since when.

- **Wait instead of failing**: `--wait-lock <seconds>` on the CLI, or the
  `fleetest.remoteWaitLock` setting (seconds; default 0 = fail immediately) in the VS Code
  extension. There is deliberately no "steal it" button in the extension.
- **See who is using it**: the LOCK column of `fleetest remote status --runner <machine>`
  (`-` means "could not tell", not "free"). The Device Monitor shows a 🔒 on that machine's
  toolbar row.
- **Live video pauses by itself during a run** — when someone's run starts, that machine's tiles
  switch from live streaming to a still image every two seconds, and switch back when the run
  finishes (streaming interferes with test execution, so this applies to your own runs too).
  If two people watch the same device, the one who opened it later gets still images.
- **Operations that would break someone's run stop first** — `fleetest remote clean` refuses
  while a run is in progress, and the extension's bulk stop / device deletion confirmations name
  the run that is in progress.

Set who you are (`issuerId` in `~/.config/fleetest/config.json`) and your name appears in those
messages. The full procedure is in `docs/remote-runner-setup.md` (maintainer-facing).

### Link
- [index](../index.md)
