# Parallel Execution

[in Japanese(日本語)](parallel_execution_ja.md)

## With a run profile

**The parallelism level equals the number of resolved devices.** Each device in a run profile
becomes a worker; scenarios are shared out across them. iOS reuses any already-running bridge
and only starts what's missing. A run profile can mix iOS and Android devices in the same
`devices` list to use iOS and Android devices together in one run (each scenario runs on only one of the two OSes — see below; see [profiles.md](../project/profiles.md)).

```bash
fleetest run --project SampleApp --profile all
```

A scenario declared with no `platform:` runs on whichever OS is the run's default (the first
platform with a worker, normally `ios` if any iOS device is present). **A scenario that declares
`platform:` explicitly, and whose declared OS isn't among the run's devices, is skipped rather
than queued** — the other OS's devices in the same profile just sit idle for it. To run a
platform-agnostic scenario on both OSes, run `--profile ios-run` and `--profile android-run` separately.

## Without a run profile (manual `--port`)

Start one bridge per Simulator, on separate ports, then hand `run` the port list:

```bash
fleetest bridge up --device "iPhone 17 Pro"                          # port 8123
fleetest bridge up --device "iPhone 17 Pro Max" --port 8124
xcrun simctl install "iPhone 17 Pro Max" <path/to/App.app>           # install on each device

fleetest run --port 8123 --port 8124    # scenarios are auto-distributed to the workers
fleetest bridge down --all              # stop every bridge
```

Android scenarios in the same run get their own worker automatically (each scenario runs in its
own subprocess, so platforms stay isolated).

## Sizing

- **More devices is not always faster.** Past the point where the Mac is saturated, each scenario
  just gets slower, the total time stays flat, and image-based steps (`findImage` / `existImage`) and
  text visual verification start to fail more often.
- So find the knee on your own Mac: add devices a few at a time and stop when the wall time of the
  run stops dropping. If a run turns red only at the higher count, go back to the lower one.
- A freshly cold-booted Simulator can time out on its accessibility IPC. Workers warm up with a
  snapshot automatically at start, but if it still fails, run `bridge up` then launch the app and take one
  snapshot by hand (MCP `ft_launch` and `ft_snapshot`; see [MCP Server](../tools/mcp_server.md)) before the real run.

## Slowing down when the Mac is busy

**When the Mac's CPU is very busy, fleetest briefly holds back before the next step** (on by default).
With the CPU pinned near 100%, image and text checks are more likely to go wrong.

- Right before a step that changes the screen (`tap`, `type`, scrolling, `launchApp` and so on), it
  measures the whole Mac's CPU usage at that moment and waits **0.2 s at 90% or more, or 1 s at 95% or
  more**, then runs the step. It waits once per step at most; it never waits for the load to go down.
- It does not wait before checks (`exist`, `textIs` and so on) or `select`, so that something that
  disappears right after an action (a Snackbar, say) is not missed. It does not wait while a
  `hold { }` is pressing, or before `tap()` on an element found by image (`findImage` and so on) —
  that taps the position where the image was found, which would go stale. Steps that use a selector
  read the screen again after the wait and find their target then.
- It does not wait before an operation marked `settle: false` either. Put `settle: false` on an
  operation that has to be quick — tapping something that disappears, or operating in quick succession.
- The wait is counted neither against the step's own limit (`waitSeconds`) nor against the scenario's
  time limit (`scenarioTimeout`), so it never makes a step or a scenario time out.
  When the Mac is not busy, nothing waits.
- It works the same for physical and virtual devices, on iOS and Android — what it measures is the Mac.

The time spent waiting is recorded in the results JSON (`pacingMs` per step, and `steps.paced` /
`steps.pacedMs` per scenario; see [results_analysis.md](./results_analysis.md)).

To change the tiers or turn it off, write it in that machine's `~/.config/fleetest/config.json`
(on a remote runner, the runner's own file is used).

```json
{
  "hostLoadPacing": {
    "tiers": [
      { "cpuPercentAtLeast": 90, "delayMs": 200 },
      { "cpuPercentAtLeast": 95, "delayMs": 1000 }
    ]
  }
}
```

To turn it off, use `"hostLoadPacing": { "disabled": true }`. If the values are not valid (a usage at
or below 0 or above 100, a negative wait, or the same usage twice), the defaults are used and a
warning is printed once at the start of the run.

## `--broadcast`

`--broadcast` is the one case that does **not** share scenarios out: it runs the selected set
once on **every** device of the run profile (e.g. a warm-up pass), rather than dividing them. It
still needs `--profile`; `--device` narrows which devices are included (when devices with the same
name exist on more than one machine, say which machine with `--runner` or `--all-machines`; see
[Remote Runners](../../fleet/remote_runners.md)). Results are told apart
by their `worker` field, since the same `scenarioID` appears once per device (see
[results_analysis.md](./results_analysis.md)).

## One run at a time per machine

**A Mac runs one fleetest run at a time.** Two runs on the same machine fight over the same
Simulators and the same loopback ports, and the load makes tests unstable — so the second one is
not started. This is deliberate, not a limit to work around.

You rarely need a second run anyway: parallelism lives *inside* one run. Put more devices in the
run profile and the scenarios are shared out across them (the sections above), rather than
starting `run` twice.

If you do start a second one:

- **On the CLI** it stops right away with `another fleetest run is already running on this Mac`,
  telling you who started the run in progress and since when. Add `--wait-lock <seconds>` to queue
  for it instead of failing; runs are served in the order they got in line.
- **In the VS Code extension** it waits by default, for up to 1 hour. Change it in the Device
  Monitor's **Settings** tab, under **Machines** → **Max wait on runner contention** (0 fails right
  away without waiting). While you are in line, the run log shows your position.

A runner machine follows the same rule: a run dispatched to it takes that machine's one slot, so
the runner is busy for everyone until it finishes — see
[Remote Runners](../../fleet/remote_runners.md).

## Other places parallel execution shows up

- The VS Code extension runs the same parallel execution through the `fleetest.profile` setting
  (see the Device Monitor section of
  [VS Code Extension](../tools/vscode_extension.md)).
- LPT ordering (longest-past-runtime-first dispatch) balances the queue across workers using
  recent run history; `--no-lpt`/`--lpt-history-runs` control it (see
  [running_scenarios.md](./running_scenarios.md)).
- Deterministic replay does not call FM, so it scales with parallelism. Self-healing (locator
  fingerprint matching) does not call FM either, so it scales the same way. `screenLooksLike` does
  call an on-device FM (one instance per machine), so it is bottlenecked by that regardless of how
  many devices you run.

### Link
- [index](../../index.md)
