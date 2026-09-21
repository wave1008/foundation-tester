# Parallel Execution

## With a run profile

**The parallelism level equals the number of resolved devices.** Each device in a run profile
becomes a worker; scenarios are shared out across them. iOS reuses any already-running bridge
and only starts what's missing. A run profile can mix iOS and Android devices in the same
`devices` list to test both OSes in one run — see [profiles.md](../project/profiles.md).

```bash
fleetest run --project SampleApp --profile all
```

A scenario declared with no `platform:` runs on whichever OS is the run's default (the first
platform with a worker, normally `ios` if any iOS device is present). **A scenario that declares
`platform:` explicitly, and whose declared OS isn't among the run's devices, is skipped rather
than queued** — the other OS's devices in the same profile just sit idle for it. To run a
platform-agnostic scenario on both OSes, run `--profile ios` and `--profile android` separately.

## Without a run profile (manual `--port`)

Start one bridge per simulator, on separate ports, then hand `run` the port list:

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

- Measured (M1 Max): 3 scenarios sequentially = 55.2s → 2+1 in parallel = 31.2s (wall time ≈
  longest scenario).
- Rule of thumb: iOS 2 + Android 2 is the sweet spot — going to 3+3 measured no further gain.
- A freshly cold-booted simulator can time out on its accessibility IPC. Workers warm up with a
  snapshot automatically at start, but if it still fails, run `bridge up` then one manual
  `launch` + `snapshot` before the real run.

## `--broadcast`

`--broadcast` is the one case that does **not** share scenarios out: it runs the selected set
once on **every** device of the run profile (e.g. a warm-up pass), rather than dividing them. It
still needs `--profile`; `--device` narrows which devices are included. Results are told apart
by their `worker` field, since the same `scenarioID` appears once per device (see
[results_analysis.md](./results_analysis.md)).

## One run at a time per machine

**A Mac runs one fleetest run at a time.** Two runs on the same machine fight over the same
simulators and the same loopback ports, and the load makes tests unstable — so the second one is
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
[remote_runners.md](../in_action/remote_runners.md).

## Other places parallel execution shows up

- The VS Code extension runs the same parallel execution through the `fleetest.profile` setting
  (see the "並列実行とログレーン" section of
  [vscode-fleetest/README.md](../../../vscode-fleetest/README.md) (Japanese)).
- LPT ordering (longest-past-runtime-first dispatch) balances the queue across workers using
  recent run history; `--no-lpt`/`--lpt-history-runs` control it (see
  [running_scenarios.md](./running_scenarios.md)).
- Deterministic replay does not call FM, so it scales with parallelism. Self-healing (locator
  fingerprint matching) does not call FM either, so it scales the same way. `screenLooksLike` does
  call an on-device FM (one instance per machine), so it is bottlenecked by that regardless of how
  many devices you run.

### Link
- [index](../index.md)
