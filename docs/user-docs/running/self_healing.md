# Self-Healing

When self-healing is enabled and a selector fails to resolve during a device run, fleetest looks
for a stand-in element in the following order before failing the scenario:

1. **Heal cache** — a selector adopted by an earlier repair (`.fleetest/heal-cache.json`).
2. **Locator fingerprint** — fleetest remembers the type and label (and the placeholder, for input
   fields) of the element a selector last resolved to. If **exactly one** element on the current
   screen matches, that element is used. This follows the typical change "the id was renamed but
   the label stayed the same" without calling FM. Elements with neither a label nor a placeholder
   are not remembered (the type alone does not identify an element), and a match with more than
   one element is never used.
3. **FM (Foundation Models)** — FM picks a stand-in from the list of elements on screen. This
   requires FM to be available (see `fleetest doctor`). **An FM proposal is adopted only when FM
   itself reports its confidence as "high".** A proposal below that is not used; instead, the
   failure message says what FM proposed, as a hint for fixing the selector.

FM features are **experimental**. See [environments.md](../overview/environments.md). In current
measurements FM proposals almost never reach "high", so most repairs in practice come from the
locator fingerprint.

Setting `heal` to false stops all three: neither the heal cache nor the locator fingerprint is
used either.

## Enabling it

- **`--profile` runs default `heal` to ON.** A plain `fleetest run` without a profile defaults it
  to OFF. `fleetest run --profile <name> --set heal=<true|false>` overrides either default for
  one run without editing the profile file (see [running_scenarios.md](./running_scenarios.md)
  for `--set`).
- In the run profile itself, `heal` (default `true`) is one of the toggles under the parent
  switch `fm` — see [run_profile.md](../project/run_profile.md). Setting `fm` to false also turns
  all three layers of self-healing off.
- In the VS Code extension, the `fleetest.heal` setting appends `--set heal=true` to Test
  Explorer's "Run" and "Debug" actions (not "Run (dry-run)", since dry-run never touches a
  device). When `fleetest.heal` is `false` (the default) and you're using `fleetest.profile`,
  the run profile's own `heal` setting is used instead.

## What happens on a repair

- A selector repaired by FM is cached per project in `TestProjects/<name>/.fleetest/heal-cache.json`,
  keyed to the source location. **On the next run, the same step passes deterministically from
  the cache — FM is not called again** for that step, unless the surrounding source changes (a
  changed key naturally invalidates the cache entry).
- A repair by locator fingerprint is not written to the heal cache; the fingerprint is matched
  again on every run. Fingerprints are kept in `TestProjects/<name>/.fleetest/locator-fingerprints.json`
  and are updated each time the step's own selector resolves directly.
- Every scenario report (`reports/scenario-*.md`) keeps listing a fix suggestion with a source
  location for as long as the source has not been updated, e.g.:

  > `TestProjects/SampleApp/scenarios/LoginTest.swift:17` — change the selector "#email_input"
  > to "#email||.textField[0]"

- **The tool never edits your `.swift` source automatically.** Applying a fix suggestion is a
  separate, explicit step.

## Reviewing and applying fix suggestions (VS Code)

When a `--set heal=true`-enabled run produces one or more fix suggestions, the VS Code extension
automatically opens a **"fleetest self-healing review"** panel (dry-run runs never trigger it).
For each candidate you can see:

- The current ("before") selector, read-only, and the proposed ("after") selector, editable.
- A diff preview of the source line.
- A checkbox to include it (pre-checked, unless the source line has changed since the panel
  opened enough that the before-selector no longer appears exactly once — those are disabled).

Clicking "Apply selected" writes the accepted fixes into your scenario source via
`fleetest api apply-heal`. Fixes that fail to apply stay in the list with a reason; the panel
closes automatically once every remaining fix has succeeded. Closing without applying leaves the
heal cache intact, so the same candidates are proposed again on the next `--set heal=true` run.

### Link
- [index](../index.md)
