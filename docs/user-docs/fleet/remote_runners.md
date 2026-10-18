# Remote Runners

[in Japanese(日本語)](remote_runners_ja.md)

These steps run your tests on another Mac (a runner machine). Your Mac sends the run over SSH, the runner executes it
just like a local run, and the output and artifacts (reports, recordings, logs) come back to your Mac.

What remote runs can do, the overview, machine names, and how a run profile decides where a run goes are in
[Fleet concepts](concepts.md).

## Before you start

The runner must already be prepared. If it is not, finish [Adding a Mac](adding_mac.md) first (preparing the runner,
SSH, registering the machine, installing fleetest on the runner and checking the connection).

In Claude Code, you can also set up with the `/fleetest-remote-setup` skill. The skill
asks what it needs to know, leaves the mechanical work to `fleetest remote setup`, hands you the
parts that need a person, and reports the result at the end. It does not do the tasks that need
sudo or the GUI, such as preparing the runner, for you.

## 1. Add the runner's devices to a run profile

Which machine runs a test is decided by the `machine` written on each device in the run profile's `devices`
("The run profile decides where tests run" in [Fleet concepts](concepts.md)).

### Prompt for the AI

```text
Find the devices on M1Max and add them to the run profile ios-run.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

In the VS Code extension, open "Select Devices" from the run profile's "Add device" button and switch "Machine:".
On the CLI, look up the runner's devices with `fleetest remote exec M1Max -- api installed-devices` and write them, with
`machine`, into the run profile's `devices`. Both are described in Step 4 of [Adding a Mac](adding_mac.md).

</details>
<br>

## 2. Run it

If the run profile's devices are on the runner, the run goes to the runner with the same prompt as any other run.
You do not need `--runner`.

### Prompt for the AI

```text
Run the scenario <scenario name> with the run profile ios-run.
```

To send just this one run to a different machine, name the machine:

```text
Run the scenario <scenario name> on M1Max with the run profile ios-run.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
fleetest run --profile <run profile> --scenario <scenario ID>        # follows the machine of the profile's devices
fleetest run --runner <name> --profile <run profile>            # send this one run to a specific machine
fleetest run --project <project> --fleet <name>                 # run the same scenarios on every machine in the fleet
fleetest run --project <project> --fleet <name> --split          # split the scenarios across the machines
```

A fleet is a list of machine and run profile pairs. Define it in
`TestProjects/<project>/profiles/fleets/<name>.json` as `host` (machine name) and `profile`
(run profile name) pairs under `runs`. Write `"local"` for your own Mac.

```jsonc
// profiles/fleets/two-runners.json
{ "runs": [
    { "host": "M1Max",   "profile": "ios-run" },
    { "host": "M2Ultra", "profile": "ios-run" } ] }
```

In a fleet definition you write the machine name under the `host` key (the key differs from the
`machine` key of a device in a run profile).

- With `--split`, instead of running the same scenarios on every machine, the scenarios are
  divided among the machines. The split is estimated from how long past runs took.
- With `--junit <path>`, the results from every machine are merged into one file. Each
  `<testsuite>`'s `hostname` tells you which machine it came from.

</details>
<br>

The first run takes a few minutes to start, because the runner builds the scenarios and so on. Later runs start within seconds.

## 3. Using it from the VS Code extension

The extension has no "choose where to run" screen. When you choose a run profile, the `machine`
its devices name decides where the run goes.

The extension can do the following (for the steps, see
[Adding a Mac](adding_mac.md)):

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
the machine name. Automatic repair of bridges also covers remote devices, but the device health
watch (Wi-Fi repair) only applies to local devices. Physical devices are excluded from both.

Services in `scripts/compose.yaml` start on the runner, so the runner also needs a container
runtime and the images (see the requirements table in [Adding a Mac](adding_mac.md)).

## 4. Sharing one runner between several people

When you send a run to a runner that someone else is using, it waits until the runner is free. The run log shows your
position in line.

### Prompt for the AI

```text
Run the scenario <scenario name> on M1Max with the run profile ios-run. If M1Max is in use, wait up to 10 minutes for your turn.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
fleetest run --runner M1Max --profile <run profile> --scenario <scenario ID> --wait-lock 600
```

`--wait-lock <seconds>` is the longest it waits for the runner to become free. While you wait, the run log shows your
position.

</details>
<br>

**Only one run at a time** can use a runner. The devices belong to that runner, so two runs are
kept from fighting over the same device. When the runner is busy, you are shown who has been
using it and since when. Your own Mac works the same way for the runs you start on it (see
[Parallel execution](../reference/running/parallel_execution.md)).

- **Wait until it is free**: this is the default, for up to 1 hour — long enough to sit through
  several runs ahead of you. Change it in the Device Monitor's **Settings** tab, under **Machines** →
  **Max wait on runner contention** (0 fails right away without waiting); the setting key is
  `fleetest.remoteWaitLock`. On the CLI, add `--wait-lock <seconds>`. While you are in line, the
  run log shows your position. The extension has no way to take over a busy runner.
- **See who is using it**: it appears in the LOCK column of
  `fleetest remote status --runner <machine>`. `-` means "could not be checked", not "free".
  The Device Monitor shows 🔒 on that machine's row in the toolbar.
- **Live video stops automatically during someone else's run**: when another person's run starts,
  that machine's tiles switch from live video to still images, and switch back when the run
  ends. Streaming interferes with test execution. The same applies to a machine whose state cannot
  be observed. For your own run, streaming continues while the Device Monitor's "Live update"
  (on by default) is on. Also, if
  two people watch the same device at once, the one who opened it later gets still images.
- **Operations that would break someone else's run stop first**: `fleetest remote clean` stops
  if a run is in progress (`--ignore-lock` overrides this, but kills that run). When you bulk-stop or delete devices in the extension, the
  confirmation shows whose run is in progress.
- **Release a dead lock**: if a dispatch died and left its lock behind, reclaim it with
  `fleetest remote unlock [--runner <machine>|local] [--force]`. Without `--force` it releases only your own
  lock; `--force` releases it whoever holds it (this breaks that run if it is still going).

If you set your name in `issuerId` in `~/.config/fleetest/config.json`, that name appears in these
messages. For setting up a runner shared by several people, see "When several people share one
runner" in [Adding a Mac](adding_mac.md).

## Good to know

### Runners on another network (across a router)

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

### Maintaining runner machines

Nobody looks at a runner machine's results, reports, and recordings the way you look at your own, so
they pile up unnoticed. Run `fleetest remote clean --runner <machine>` from time to time. You can check the free
space with `fleetest remote status`. `remote clean` stops if a test is running (`--ignore-lock` overrides this, but kills that run).

When you update fleetest on your Mac, bring the runner machines to the same version too (see "When you update fleetest"
in [Adding a Mac](adding_mac.md)).

### Using it safely

- The only path is **SSH with key-based authentication**. No password prompt is used, and
  **relaxed host-key checking is never used**.
- Every argument sent to the runner is quoted.
- **Trust model**: the runner machine itself is trusted (SSH access already means it can execute
  arbitrary code as that user). What comes back from the runner, however, is treated as external
  input.
- The runner ends up holding keys, sources, scenarios, reports, and **recordings**.
  **Recordings and screenshots can show credentials typed during a test.** In a shared lab other
  users can read them too, so do not put production credentials in scenarios or profiles.
- For using a runner machine across a router, see "Runners on another network (across a router)" above.

### Link
- [index](../index.md)
