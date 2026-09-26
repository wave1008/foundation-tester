# Self-Healing

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
  OCR-based toggles (`fmTextOcclusionCheck`, `screenLooksLike`, `ocrTextOcclusionCheck`) — see
  [run_profile.md](../project/run_profile.md).
- In the VS Code extension, the `fleetest.heal` setting appends `--set heal=true` to Test
  Explorer's "Run" and "Debug" actions (not "Run (dry-run)", since dry-run never touches a
  device). When `fleetest.heal` is `false` (the default) and you're using `fleetest.profile`,
  the run profile's own `heal` setting is used instead.

## What happens on a repair

- A repair by locator fingerprint is not cached; the fingerprint is matched again on every run.
  Fingerprints are kept in `TestProjects/<name>/.fleetest/locator-fingerprints.json` and are
  updated each time the step's own selector resolves directly.
- Every scenario report (`reports/scenario-*.md`) keeps listing a fix suggestion with a source
  location for as long as the source has not been updated, e.g.:

  > `TestProjects/SampleApp/scenarios/LoginTest.swift:17` — passed via locator fingerprint
  > matching; change the selector "#email_input" to "#email||.textField[0]"

- If the matched element has no selector that can be written uniquely, the step still acts on it,
  but no fix suggestion is made for it.
- **The tool never edits your `.swift` source automatically.** Applying a fix suggestion is a
  separate, explicit step.

## Reviewing and applying fix suggestions (VS Code)

When a `--set heal=true`-enabled run produces one or more fix suggestions, the VS Code extension
automatically opens a **"fleetest Heal Review"** panel (dry-run runs never trigger it).
For each candidate you can see:

- The current ("before") selector, read-only, and the proposed ("after") selector, editable.
- A diff preview of the source line.
- A checkbox to include it (pre-checked, unless the source line has changed since the panel
  opened enough that the before-selector no longer appears exactly once — those are disabled).

Clicking "Apply N selected" writes the accepted fixes into your scenario source via
`fleetest api apply-heal`. Fixes that fail to apply stay in the list with a reason; the panel
closes automatically once every remaining fix has succeeded. Closing without applying leaves the
same candidates to be proposed again on the next `--set heal=true` run (fingerprint matching runs
fresh every time, so nothing needs to be invalidated).

### Link
- [index](../index.md)
