# Sharing the test project until a second person runs it

[in Japanese(日本語)](sharing_project_ja.md)

The steps for sharing the scenarios and profiles you made through git, until a second person runs them on their own Mac.
It assumes you have a work folder where you finished the [Quick Start](../quick-start.md).

## 1. Check what goes into git and what does not

Open the `.gitignore` of the work folder (the folder that holds `Package.swift`).

### Prompt for the AI

```text
Show me the contents of this work folder's .gitignore. List the files that go into git and the files that do not.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
cat .gitignore
git status --short
```

</details>
<br>

Expected result:

- `fleetest init` and the installer add these three lines to `.gitignore` (when the work folder is a git repository).

```text
.build/
.fleetest/
TestProjects/*/reports/
```

| Goes into git | Stays out of git (the first three are excluded by `.gitignore`) |
|---|---|
| `Package.swift` | `.build/` (build products) |
| `TestProjects/<project>/scenarios/` (scenarios) | `.fleetest/` (state of this Mac) |
| `TestProjects/<project>/profiles/` (app and run profiles) | `TestProjects/*/reports/` (Markdown reports; they contain screen text) |
| `TestProjects/<project>/workspace/scripts/compose.yaml` (server declarations; [Services the app depends on](../reference/writing/services.md)) | `.mcp.json` (contains absolute paths, so it differs per Mac; it is not added to `.gitignore` automatically, so do not `git add` it or add it yourself) |
| `TestProjects/<project>/dataset/` (test data that is fine to share) | The contents of `~/.config/fleetest/` (outside the work folder, so never in git to begin with) |
| `TestProjects/<project>/docs/` (if present) | |

- `results/` is not added to `.gitignore` automatically. Result JSON is written in a form that merges across several Macs
  ("Layout" in [Analysing results (fleetest results, dashboard)](../reference/running/results_analysis.md)), but recordings
  also go under the same `results/runs/<month>/<runID>/`. **Recordings show screen text and are large**, so before sharing look at what
  has grown with `git status` and decide
  ([Checking what a test leaves behind](../security/test_outputs.md)).
- Do not put secrets or passwords into the repository. See step 5 below.

## 2. Commit and push

### Prompt for the AI

```text
Pick only what should go in from git status and commit it. Leave out results/ and reports/. Don't push yet; show me what the commit contains.
```

Once you have checked the contents, tell it to push.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
git add Package.swift .gitignore TestProjects/
git status --short           # confirm reports/ and results/ are not included
git commit -m "Add fleetest test project"
git push
```

</details>
<br>

## 3. The second person clones and sets up

The second person clones the repository on their own Mac and opens it in VSCode. Each person has their own clone of fleetest,
so they set up with the same prompt as step 3 of the Quick Start.

### Prompt for the AI

```text
Clone https://github.com/wave1008/foundation-tester next to this folder and
set it up following ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

When setup is done, register the `TestProjects/` that came with the clone in `Package.swift`.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest project sync
../foundation-tester/.build/debug/fleetest project list
```

`project sync` scans `TestProjects/` and regenerates the marker section of `Package.swift`
(needed after a manual copy or a `git pull`; "Managing projects" in [Creating a test project](../reference/project/creating_project.md)).

</details>
<br>

Expected result:

- `project list` lists the shared project with its run profile names.
- It is registered when the line carries no `⚠️ not registered in Package.swift` note (if it does, `project sync` has not run yet).

## 4. Prepare the second person's devices

A run profile's `devices` point at devices by **name**. An iOS Simulator is looked up by `name` (the Simulator's own name) and
`osVersion`, and an Android device by `avd` ("Devices" in [Profiles](../reference/project/profiles.md)).
`fleetest run` does **not create** a device it cannot find. If the second person's Mac has no Simulator with the same name and OS,
iOS stops with `simulator not found: <name>(<OS>)` followed by the names of the Simulators on that Mac.
Android tries to start that AVD, fails three times (this takes a few minutes), then stops with
`no running emulator for AVD "<avd>"` followed by the Emulators that are running (the Emulator's own log says `Unknown AVD name`).

There are two ways to fix it.

- Create a Simulator / Emulator with the same name and the same OS.
- The second person makes **their own run profile**. This does not rewrite the shared profile, so it cannot break the first
  person's setup. The app profile stays the shared one.

### Prompt for the AI

```text
Create my own run profile ios-run-mine that uses the shared ios-app app profile.
For the device, pick the newest-OS Simulator available on this Mac.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id <bundle ID> \
  --app-ref ios-app --run ios-run-mine --auto-device
../foundation-tester/.build/debug/fleetest profile list
```

`--auto-device` picks a Simulator / Emulator that fits this Mac, creating one if there is none.
The app profile's `appPath` is the location of the built app, so check that it is found at the same path on the second person's Mac too
(if not, the second person builds the app and adjusts the path).

</details>
<br>

## 5. The second person runs it

### Prompt for the AI

```text
Run all the scenarios with the fleetest ios-run-mine profile.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run-mine
```

</details>
<br>

The following belong **to that Mac** and are not shared. The second person prepares them themselves.

- The `account()` values in files such as `~/.config/fleetest/dataset/<project>/accounts.json`
  ("Where the files go, and overriding" in [Test data and accounts](../reference/commands/dataset.md)).
  Without them, a step that calls `account()` fails, and the failure message shows the paths of the files it looked at.
- `~/.config/fleetest/secrets/<project>.env` (secrets that compose.yaml refers to;
  "Secrets" in [Services the app depends on](../reference/writing/services.md)).
- `~/.config/fleetest/config.json` (machine settings; [Machine settings (config.json)](../reference/project/machine_settings.md)).

## 6. Two people use the same runner machine

A runner machine runs **only one run at a time**. When two people submit at once, the later one can either wait or fail.
Try it. Two people ask their AI assistants at nearly the same time (`M1Max` is the name of a registered runner machine).

### Prompt for the AI

```text
Run all scenarios with the fleetest ios-run profile on M1Max. If M1Max is in use, wait in line for up to 10 minutes.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

In two terminals, type the following at nearly the same time.

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --runner M1Max --wait-lock 600
```

</details>
<br>

Expected result:

- The one that was typed first starts running.
- The other prints its place in the queue in the execution log and waits, then starts when the first run finishes.
- Without `--wait-lock`, the later one stops, reporting that the runner is in use and who has been using it since when.

You can see who is using it in the LOCK column of `fleetest remote status --runner M1Max`. To have your name appear in these displays,
write `issuerId` in `~/.config/fleetest/config.json`. How to wait, how to release a lock, and the settings are in
"Sharing one runner between several people" in [Remote Runners](../fleet/remote_runners.md).
Adding a runner machine is covered in [Adding a Mac](../fleet/adding_mac.md).

## 7. Review scenarios the AI wrote

Scenarios you share are checked by a person even when the AI wrote them. The points to look for are the headings of
[Writing Robust Scenarios](../reference/writing/writing_robust_scenarios.md). The body text is there.
Making the list is something you can ask the AI to do.

### Prompt for the AI

```text
Review the fleetest scenarios against the guidance for writing robust scenarios and list what should be fixed. Do not fix anything until I have checked the list.
```

- Don't add `wait` for element appearance
- Take selectors from a real screenshot, not from memory
- Don't leave coordinate taps in a scenario
- Wrap anything that may or may not appear
- Always put an assertion in `expectation`
- Failure aborts the whole scenario — `afterEach` still runs
- Don't pin `app:` / `platform:` if the scenario should run on both OS
- Read a value before it can change
- Never retry an irreversible action

## Next

- [Running on CI](ci.md)
- [Checking what a test leaves behind](../security/test_outputs.md)

### Link
- [index](../index.md)
