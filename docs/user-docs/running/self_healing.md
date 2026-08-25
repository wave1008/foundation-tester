# Self-Healing

When self-healing is enabled and a selector fails to resolve during a device run, FM (Foundation
Models) repairs the locator on the fly so the run continues, instead of failing the scenario
outright. This requires FM to be available (see `fleetest doctor`).

FM features are **experimental and English-only for now** — the Mac's system language must be
English, and Japanese is not supported by the model during 2026 (2027 is expected). See
[environments.md](../overview/environments.md).

## Enabling it

- **`--profile` runs default `heal` to ON.** A plain `fleetest run` without a profile defaults it
  to OFF. `fleetest run --heal` / `--no-heal` override either default (mutually exclusive).
- In the run profile itself, `heal` (default `true`) is one of the FM toggles under the parent
  switch `fm` — see [run_profile.md](../project/run_profile.md).
- In the VS Code extension, the `fleetest.heal` setting appends `--heal` to Test Explorer's "Run"
  and "Debug" actions (not "Run (dry-run)", since dry-run never touches a device). When
  `fleetest.heal` is `false` (the default) and you're using `fleetest.profile`, the run profile's
  own `heal` setting is used instead.

## What happens on a repair

- The healed selector is cached per project in `TestProjects/<name>/.fleetest/heal-cache.json`,
  keyed to the source location. **On the next run, the same step passes deterministically from
  the cache — FM is not called again** for that step, unless the surrounding source changes (a
  changed key naturally invalidates the cache entry).
- Every scenario report (`reports/scenario-*.md`) keeps listing a fix suggestion with a source
  location for as long as the source has not been updated, e.g.:

  > `TestProjects/SampleApp/scenarios/LoginTest.swift:17` — change the selector "#email_input"
  > to "#email||.textField[0]"

- **The tool never edits your `.swift` source automatically.** Applying a fix suggestion is a
  separate, explicit step.

## Reviewing and applying fix suggestions (VS Code)

When a `--heal`-enabled run produces one or more fix suggestions, the VS Code extension
automatically opens a **"fleetest self-healing review"** panel (dry-run runs never trigger it).
For each candidate you can see:

- The current ("before") selector, read-only, and the proposed ("after") selector, editable.
- A diff preview of the source line.
- A checkbox to include it (pre-checked, unless the source line has changed since the panel
  opened enough that the before-selector no longer appears exactly once — those are disabled).

Clicking "Apply selected" writes the accepted fixes into your scenario source via
`fleetest api apply-heal`. Fixes that fail to apply stay in the list with a reason; the panel
closes automatically once every remaining fix has succeeded. Closing without applying leaves the
heal cache intact, so the same candidates are proposed again on the next `--heal` run.

### Link
- [index](../index.md)
