# Remote Runners

`fleetest run --runner <machine>` runs your tests on another Mac (a runner machine). Your Mac
sends the run over SSH, the runner executes it just like a local run, and the output and
artifacts come back to your Mac.

This page covers what remote runs can do and how they work. The setup steps are in
[Setting Up a Remote Runner](remote_runner_setup.md).

## What it can do

| Capability | Supported |
|---|---|
| Send a run to another Mac (from the CLI or the VS Code extension) | ✅ |
| Progress display, cancellation, timeout | ✅ |
| Bring reports, JUnit, recordings and run logs back to your Mac | ✅ |
| Provision a runner from your Mac in one command (`remote setup`); remove it the same way (`remote teardown`) | ✅ |
| Check or clean up several runners at once (`remote status` / `remote clean`) | ✅ |
| Run a single `fleetest` command on a runner (`remote exec`) | ✅ |
| Run on several runners at the same time (a fleet, `run --fleet`) | ✅ |
| Split one set of scenarios across several runners (`run --fleet <name> --split`) | ✅ |
| Include remote results in `fleetest results` (flaky detection etc.) | ✅ (collected by default) |
| See remote devices' state and video in the Device Monitor | ✅ |

Scenarios and profiles are sent from your Mac to the runner automatically on every run. You edit
them only on your Mac; you never edit files on the runner directly.

## Overview

```
Issuing Mac (yours)                     Runner machine
fleetest run --runner mac2 …             ~/fleetest-runner/               ← dedicated base directory
  ├ compatibility check (rev, Xcode) ssh ├── foundation-tester/          ← the tool's clone (fixed name, shared)
  ├ transfer (rsync: scenarios/config) ─> └── users/<issuerId>/work/     ← your work area (per issuer)
  ├ display output                             ├── TestProjects/<project>/
  └ collect artifacts <──────────────────      └── .build/
```

Remote runs only use `~/fleetest-runner/` on the runner. If the runner has its own copy of
foundation-tester elsewhere, it is never touched.

## Setup

The setup steps, for both the CLI and the VS Code extension, are in
[Setting Up a Remote Runner](remote_runner_setup.md). The flow is:

1. Prepare the runner (on the runner, by hand)
2. Set up SSH key login
3. Register the machine
4. Install fleetest on the runner (`fleetest remote setup`)
5. Add the runner's devices to your profiles
6. Check the connection and run your first test

In Claude Code, you can also set up with the `/fleetest:fleetest-remote-setup` skill. The skill
asks what it needs to know, leaves the mechanical work to `fleetest remote setup`, hands you the
parts that need a person, and reports the result at the end. It does not do the tasks that need
sudo or the GUI, such as preparing the runner, for you.

## Machine names

To point at a runner, you use a name you give it on your Mac, not its host name or IP address.
This name is called the **machine name**.

- **Host**: the real network destination. Example: `<user@192.168.xxx.xxx>`
- **Machine**: a name for that host, known only on this Mac. Example: `M1Max`. This is what
  profiles refer to.

Register machine names with `fleetest remote machines add` or in the Device Monitor's Settings
tab (see Step 2 of [Setting Up a Remote Runner](remote_runner_setup.md)).

Renaming a machine later causes no trouble. Records such as result JSON keep the host name, and
the machine name never appears in the files or arguments sent to the runner.

## A run profile's devices decide where a run goes

Each device in a run profile names its own machine in `machine`:

```jsonc
// profiles/runs/ios-m1max.json
{ "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "M1Max", "name": "simulator1", "simulator": "iPhone 17 Pro" }
  ] }
```

So **choosing a run profile also chooses which machine runs it**, and you normally do not need
`--runner`. If a run profile's enabled devices all live on one remote machine, the run
automatically dispatches there. If they span several machines (some `"local"`, some remote), the
run splits per machine and each portion runs against its own devices there.

- Write `"machine": "local"` for devices on your own Mac — always write it explicitly, since
  there is no profile-level default to fall back on.
- `--runner <name>` on the command line takes priority over the profile (pass `--runner local` to
  force a run to stay on your Mac). Besides a machine name, `--runner` also accepts a host name
  or IP address directly.
- Devices written with the old key `"host"` are still read (renamed to `machine` on 2026-08-26).

## `run --runner` and `--fleet`

```bash
fleetest run --runner <name> --profile <run profile>            # send this one run to a specific machine
fleetest run --project <project> --fleet <name>                 # run the same scenarios on every machine in the fleet
fleetest run --project <project> --fleet <name> --split          # split the scenarios across the machines
```

A fleet is a list of machine and run profile pairs. Define it in
`TestProjects/<project>/profiles/fleets/<name>.json` as `host` (machine name) and `profile`
(run profile name) pairs. Write `"local"` for your own Mac.

- With `--split`, instead of running the same scenarios on every machine, the scenarios are
  divided among the machines. The split is estimated from how long past runs took.
- With `--junit <path>`, the results from every machine are merged into one file. Each
  `<testsuite>`'s `hostname` tells you which machine it came from.

## Runners on another network (across a router)

A runner does not have to be on the same LAN as your Mac. Any Mac you can reach with
`ssh <target> 'echo ok'` works. Only whole run jobs travel over the network, so remote runs stay
fairly stable even with network latency.

- **The only connection you open is SSH from your Mac to the runner.** Your Mac does not need to
  accept incoming connections. File transfers, progress, artifact collection and live video all
  travel inside that one SSH connection.
- **Put port numbers and jump hosts in `~/.ssh/config`.** A target cannot be written as
  `host:2222` (targets containing `:` or whitespace are rejected). Define an alias in
  `~/.ssh/config` with `Host mac2` / `HostName` / `Port` / `ProxyJump`, and use that alias as the
  target.
- **Do not expose the SSH port directly to the internet.** Connecting over a VPN (Tailscale or
  similar) is the intended setup. If you must forward a port, forward only one, restrict the
  source IP addresses, and disable password authentication in the runner's sshd.
- **Do not open Screen Sharing (port 5900) on the router.** Instead, open a tunnel with
  `ssh -L 5900:localhost:5900 <target>` and connect to `vnc://localhost:5900`.
- **A slow link keeps working with reduced features instead of breaking.** When live video
  cannot be established, tiles switch to still images. While the connection is briefly down,
  a tile shows `unknown`. This means "the state could not be checked", not "free". Collecting
  recordings is what puts the heaviest load on the link.

**When physical devices are attached to the runner**, the network route from your Mac does not
matter; only the runner's own LAN does. Over USB, nothing needs to be configured. A LAN-attached
iPhone listens and the Mac connects to it, so no firewall change is needed on the Mac either.
You do need both of the following:

- The runner and the device are on the same subnet
- Client isolation (privacy separator) on the access point is turned off

## Using it from the VS Code extension

The extension has no "choose where to run" screen. When you choose a run profile, the `machine`
its devices name decides where the run goes.

The extension can do the following (for the steps, see
[Setting Up a Remote Runner](remote_runner_setup.md)):

- **Register machines**: in the "Machines" table of the Device Monitor's Settings tab. It reads
  and writes the same registry as the CLI's `fleetest remote machines`.
- **Add devices to a run profile**: the run profile section's "Add device" button opens "Select
  Devices"; switching "Machine:" there lists the devices on that machine. You can also create a
  new device right there. Each added device gets the chosen machine name written as its `machine`
  (`"local"` for your own Mac).
- **Align versions before a run**: before a run starts, it checks whether the runner's fleetest
  is on the same version as your Mac. If not, "Update and run" brings it in line.

Installing fleetest on a runner (`fleetest remote setup`) cannot be done from the extension. Use
the terminal.

Registered remote devices can be viewed and operated in the Device Monitor just like local ones,
including state, live video and per-tile start/stop. The only visible difference is a badge with
the machine name. However, automatic repair of bridges and device health only applies to local
devices.

## Sharing one runner between several people

**Only one run at a time** can use a runner. The devices belong to that runner, so two runs are
kept from fighting over the same device. When the runner is busy, you are shown who has been
using it and since when.

- **Wait until it is free**: on the CLI, add `--wait-lock <seconds>`. In the VS Code extension,
  set `fleetest.remoteWaitLock` to a number of seconds (the default 0 fails right away without
  waiting). The extension has no way to take over a busy runner.
- **See who is using it**: it appears in the LOCK column of
  `fleetest remote status --runner <machine>`. `-` means "could not be checked", not "free".
  The Device Monitor shows 🔒 on that machine's row in the toolbar.
- **Live video stops automatically during a run**: when someone's run starts, that machine's
  tiles switch from live video to a still image every two seconds, and switch back when the run
  ends. Streaming interferes with test execution, so this applies to your own runs too. Also, if
  two people watch the same device at once, the one who opened it later gets still images.
- **Operations that would break someone else's run stop first**: `fleetest remote clean` stops
  if a run is in progress. When you bulk-stop or delete devices in the extension, the
  confirmation shows whose run is in progress.

If you set your name in `issuerId` in `~/.config/fleetest/config.json`, that name appears in these
messages. For setting up a runner shared by several people, see "When several people share one
runner" in [Setting Up a Remote Runner](remote_runner_setup.md).

### Link
- [index](../index.md)
