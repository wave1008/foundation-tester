# Response measurement (experimental)

[in Japanese(日本語)](response_measurement_ja.md)

Run your existing scenarios on a physical device and measure, step by step, **how long the app takes to react to an action** and
**how long until the next action becomes possible**. The values are kept in the results and can be compared with the previous
measurement on the same machine and the same device.

> **Experimental.** Works with **one Android or iOS physical device** (not the Simulator or the Emulator).

## What is measured

For every step that moves the screen (`tap`, `swipe`, `scroll`, …) the run records the values below. Verification steps (`exist`, …)
and `select` steps are not measured.

| Value | Meaning |
|---|---|
| Time to first frame (`firstFrameMs`) | From injecting the input to the first frame the app presents |
| Time until ready (`readyMs`) | From injecting the input until **the element the scenario operates next** can be found, is enabled, is not covered by another element and has stopped moving |

All times are taken on the device's clock, so the communication time between the Mac and the device is not included.

**Time until ready** is decided by the element the scenario actually operates next. If a scenario taps "Log in" and then taps
"My page", the value for "Log in" is "from the tap until the My page button can be pressed".

## Turning it on

Write `responseMeasurement: true` in the run profile (`profiles/runs/<name>.json`).

```json
{
  "app": "my_app",
  "devices": [
    { "platform": "android", "name": "Pixel 8", "kind": "physical", "serial": "XXXXXXXX" }
  ],
  "responseMeasurement": true,
  "responseRepeat": 5
}
```

To try it once without editing the profile, override it with `--set`.

```sh
fleetest run --profile <name> --set responseMeasurement=true --set responseRepeat=3 --scenario <scenario ID>
```

- The profile must have **exactly one enabled device, and it must be an Android or iOS physical device (`kind: physical`)**. Otherwise
  the run is refused.
- `responseRepeat` (default `5`, `1` to `50`) sets how many times each scenario runs back to back. More repeats give a steadier
  median and p90. The result files are named `<id>`, `<id>~2`, `<id>~3`, …
- To keep the conditions even, measurement mode does the following:
  - It keeps the app's animations (`enableAnimations` is forced on). Times measured with animations off do not reflect what
    users experience.
  - It turns off the text visibility check (`fmTextVisibilityCheck`, `ocrTextVisibilityCheck`), `screenLooksLike`, recording
    (`record`) and host-load pacing.
  - It holds the device monitor's observation and streaming for the duration of the run (released at the end; a hold you set
    yourself with `fleetest monitor pause` is left as it is).
- It cannot be combined with the following (the run stops with a named error): `enableAnimations: false`; `fmTextVisibilityCheck`,
  `ocrTextVisibilityCheck`, `screenLooksLike` or `record` set to `true`; `--broadcast`, `--fleet`, `--split`.

Before every action, measurement mode waits for the app to stop drawing (up to 10 seconds), so a run takes longer than usual.

## Reading the results

```sh
fleetest results response [--project <name>] [--since <period>] [--json]
```

This collects only measurement-mode runs and lists them per step.

| Column | Meaning |
|---|---|
| `scenario` / `step` | The scenario and a step within it (identified by scene, section, command, description and occurrence of the same combination) |
| `device` / `host` | The device (serial) and the machine that ran it |
| `n` / `median ms` / `p90 ms` | Sample count, median and p90 of the time to first frame |
| `busy` | How many times the app was still drawing before the action, so the first frame was not measured (see "When a value is missing") |
| `ready n` / `ready median ms` / `ready p90 ms` | Sample count, median and p90 of the time until ready |
| `prev median ms` / `delta` | The median time to first frame of the previous measurement run on the same machine and device, and the change from it |

- Only runs on **the same machine and the same device** are compared. Runs on a different machine or device are never compared.
- The change is listed as a fact; it never fails a test. A change based on few samples may be indistinguishable from noise.
- With `--json`, each row also carries the breakdown of the reasons a value is missing (the values in the tables below).

Each individual value is also kept in the result JSON (`results/runs/.../scenarios/<id>.json`) under each step's `response`.

The scenario report (`reports/scenario-*.md`) shows the values after the duration of each measured step: ` · first frame 54 ms · ready 72 ms`. When a value is missing it shows the reason instead (`first frame - (busyBeforeAction)`); when the ready time was not judged, the `ready` part is left out. The `ready` value of a step arrives with the next measured step, so the last measured step of a scenario has none.

## When a value is missing

When a step has no value, the reason is kept as a fact. When the reason cannot be stated, the field is left out.

**Time to first frame** (`firstFrameMissing`)

| Reason | Meaning |
|---|---|
| `busyBeforeAction` | The app was already drawing before the action (it did not stop within 10 seconds). Its "first frame" would only continue the earlier drawing, so it is not measured |
| `noInjectedInput` | The step did not inject an input event (it was performed through an accessibility action, or by adb on the Mac side, …) |
| `noFrame` | The app presented no frame after the input |
| `frameHistoryIncomplete` | The frame history was too short to confirm the frames right after the input |
| `noSessionApp` | The target app could not be confirmed |
| `bridgeError` | Communication with the device side failed |

**Time until ready** (`readyMissing`)

| Reason | Meaning |
|---|---|
| `notReadyBeforeNextAction` | The conditions were not met by the time the next action was performed |
| `observationTimeout` | The conditions were not met within the observation limit (10 seconds) |
| `observationTruncated` | The recording limit was reached and the rest could not be recorded |
| `observationLost` | The observation could not be found on the device side |
| `noTarget` | The next action had no element (for example a coordinate tap) |
| `bridgeError` | Communication with the device side failed |

In the following cases there is neither a time until ready nor a reason (the step was not judged):

- the **last** action of a scenario (there is no next action)
- the next action searched by scrolling before acting (the screen position shifts)
- the scenario failed before the next action

## Things to know

- **When the next element stays in the same place throughout a screen transition (a tab bar, …), the time until ready is a few
  milliseconds.** It means that element could be pressed from the start of the transition.
- Time until ready is judged from the element information on the screen (found, enabled, not covered, not moving). It does not
  check whether the screen's pixels have stopped changing.
- A step that injects input several times in one action (searching by scrolling, repeated flicks, …) is measured from the
  **first** injection, and only conditions met after the **last** injection count.
- Run measurements while the device is not used for anything else. The monitor hold applies only within the clone that started
  the run.

### Measuring on an iOS physical device

- On iOS, **time to first frame** is recorded with Xcode Instruments (`xctrace`) during the run and filled into the results when
  the run ends. Xcode must be installed and able to record the device with Instruments. If recording fails, the run prints one line
  saying so and leaves the value empty.
- **Time to first frame** also includes the time XCUITest takes to deliver the input to the device (it reads longer than on Android).
- **Time until ready** is coarser than on Android, because reading the screen's element information takes a few hundred
  milliseconds each time (`observedReads` in the result JSON is the number of reads the judgement could use).
- The device's Reduce Motion setting cannot be changed by the tool; the device is measured with its own setting.

Related: [Run profile](../project/run_profile.md) / [Analysing results](./results_analysis.md) / [Running scenarios](./running_scenarios.md)

### Link
- [index](../../index.md)
