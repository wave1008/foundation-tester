# Self-Healing

[in Japanese(日本語)](self_healing_ja.md)

When self-healing is enabled and a selector fails to resolve during a device run, fleetest looks
for a stand-in element in the following order before failing the scenario:

1. **Primary selector**, then **your written fallbacks** (`a||b`), as usual.
2. **Locator fingerprint** — fleetest remembers the type and label (and the placeholder, for input
   fields) of the element the step's selector last resolved to directly. If **exactly one**
   element on the current screen matches that fingerprint, it is used. This follows the typical
   change "the id was renamed but the label stayed the same" deterministically. Elements with
   neither a label nor a placeholder are never remembered (the type alone does not identify an
   element), and a match with more than one element is never used.

Self-healing is fingerprint matching only — it does not call FM (Foundation Models).

## Enabling it

- **`--profile` runs default `heal` to ON.** A plain `fleetest run` without a profile defaults it
  to OFF. `fleetest run --profile <name> --set heal=<true|false>` overrides either default for
  one run without editing the profile file (see [running_scenarios.md](./running_scenarios.md)
  for `--set`).
- In the run profile itself, `heal` (default `true`) is its own toggle, independent of the FM- and
  OCR-based toggles (`fmTextVisibilityCheck`, `screenLooksLike`, `ocrTextVisibilityCheck`) — see
  [run_profile.md](../project/run_profile.md).
- In the VS Code extension, the `fleetest.heal` setting appends `--set heal=true` to Test
  Explorer's "Run" and "Debug" actions (not "Run (dry-run)", since dry-run never touches a
  device). When `fleetest.heal` is `false` (the default) and you're using `fleetest.profile`,
  the run profile's own `heal` setting is used instead.

## What happens on a repair

- A scenario that passed through a repair **stays passed** (the exit code is still `0`). Instead, `fleetest run` ends
  with a ⚠️ line saying that N scenarios passed only after self-healing. In the JUnit report from `--junit`, that
  scenario's `<system-out>` carries the number of repaired steps and the fix suggestions (file, line, old and new
  selector). This is where you catch selectors going stale while CI stays green.
- A repair by locator fingerprint is not cached; the fingerprint is matched again on every run.
  Fingerprints are kept in `TestProjects/<name>/.fleetest/locator-fingerprints.json` and are
  updated each time the step's own selector resolves directly.
- The scenario report (`reports/scenario-*.md`) of the run in which a repair happened lists a fix
  suggestion with a source location, e.g.:

  > `TestProjects/SampleApp/scenarios/LoginTest.swift:17` — change the selector "#email_input" to
  > "#email||.textField[1]" (passed via locator fingerprint matching; reason: matched by locator
  > fingerprint (type+label))

  After the fix has been written back, the next run resolves the new selector directly, so no repair happens.

- If the matched element has no selector that can be written uniquely, the step still acts on it,
  but no fix suggestion is made for it.

## Automatic write-back to the source

At the end of the run, the fix suggestions (those with file, line, old and new selector) are
**written back to your scenario `.swift` sources automatically**. This assumes the project is kept in
git: review the changes with `git diff` and commit them (the tool never commits).

- **Who writes:** the side that receives the results. That is `fleetest run` (with or without a
  profile), `fleetest api run` (used by the VS Code extension), and the MCP tools `ft_run_scenario`
  and `ft_start_run`. For remote runs (`--runner <host>` / fleet), the issuing Mac writes after it
  collects the results; the runner Mac never rewrites its own copy. Dry-run never writes.
- **Runs split across machines** (`--fleet`, or a profile whose devices span several machines) write
  once, after every machine has finished, using all the suggestions together. Different suggestions
  for the same place from different machines are not written either.
- **Write-back rules:**
  - The old selector must occur exactly once on that line as a Swift string literal; it is then
    replaced by the new selector.
  - If the same place (file, line, old selector) got different new selectors (for example the same
    scenario on several devices matched different elements), nothing is written for that place.
  - Identical suggestions are written once.
  - Files outside this project's `scenarios/` folder and symbolic-link files are never written.
  - If the line already contains the new selector and not the old one, it counts as already
    written (no error).
  - If the line changed (you edited the file after the build), it is not written and the reason is
    reported.
- Concurrent runs writing to the same project are serialized with a lock file,
  `<project>/.fleetest/heal-writeback.lock`.
- The scenario reports and the `--junit` `<system-out>` carry the fix suggestions whether or not
  they were written back.

After the existing ⚠️ line, the run output prints the following (to stderr for `fleetest api run`):

```text
✏️ Self-healing wrote 1 selector fix(es) back to the scenarios — review them with git diff and commit:
   - scenarios/LoginTest.swift:17: "#email_input" → "#email||.textField[1]"
```

Anything that could not be written is listed with its reason; the suggestions stay in the scenario reports:

```text
⚠️ Self-healing could not write 1 selector fix(es) back (the suggestions stay in the scenario reports):
   - scenarios/LoginTest.swift:17: <reason>
```

To avoid write-back, turn self-healing off (`--set heal=false`, or `heal: false` in the run profile).

### VS Code extension

When a non-dry-run run ends with fix suggestions, the extension shows a notification with the number of
fixed selectors. The run log lists what was written back and what could not be. The "Show Changes"
button opens VS Code's Source Control view; review the git diff and commit.

### Link
- [index](../../index.md)
