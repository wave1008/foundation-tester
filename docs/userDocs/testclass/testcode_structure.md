# Test Code Structure

A scenario is built from `scenario → scene → condition/action/expectation` (CAE). This page
explains what each level means for execution and reporting.

## The CAE chain

Within one `scene`, `condition` / `action` / `expectation` can be chained repeatedly by
connecting the blocks with `.`:

```swift
scene(2, "Navigate to a detail screen and back") {
    action {
        tap("#nav_selector")
    }.expectation {
        select("#screen_title").textIs("Selector")
    }.action {
        tap("#btn_back")
    }.expectation {
        select("#screen_title").textIs("Home")
    }
}
```

`condition` sets up the state the scene needs (often `launchApp()`), `action` performs
operations, and `expectation` asserts. A scene does not need all three, and — as above — you
can alternate `action`/`expectation` as many times as the flow needs.

**Scene numbers and titles become report headings.** Reports are organized
`scene → condition/action/expectation → step`, so pick numbers and titles that describe what
the scene is proving, not just "step 2".

## Failure semantics

A failing command aborts the whole scenario: **every step after it is skipped, across all
remaining scenes** — not just the rest of the current scene. `tearDown()` is the one
exception; it still runs.

**Raw Swift code inside a block is not skipped** by this mechanism (only DSL commands are).
If you have plain Swift logic you don't want to run after an earlier failure, wrap it in
`procedure { }` (see [Descriptors](../commands/descriptors.md)) so it participates in the
same skip behavior.

## Per-step time limit

Each command (each step) has a **120-second wall-clock cap**. If it doesn't return in time,
the step fails and the in-flight work is cancelled rather than left running in the
background.

## Structuring and passing values

`group("name") { }` labels a run of steps in the report without changing execution or
failure behavior. `procedure("description") { }` runs arbitrary Swift (including
`try`/`await`) as a single recorded step — this is how irregular handling and test-data
setup are written directly in code instead of a fixed DSL vocabulary. Details:
[Descriptors](../commands/descriptors.md).

## Unasserted scenarios are flagged

If an `expectation { }` block contains no assertion commands, a warning is added to the
report and log (not a failure) — this catches scenarios that perform actions but never
check anything. `ftester run --dry-run` (or `ft_dry_run`) finds this without touching a
device; see [dry-run](../running/dry_run.md).

## Branching by OS

Two mechanisms exist for OS-specific behavior, at different levels:

- **`@TestClass(platform:)` / `@Test(platform:)`** declare that a whole class or method only
  applies to one OS. On a run that doesn't cover that OS, the scenario is recorded as
  skipped (not executed, not counted as failed).
- **`ios { }` / `android { }`** branch *inside* a scene, when most of the scenario is shared
  but a few steps differ by platform (e.g. a control that only exists on one OS).

Use `platform:` when an entire test doesn't apply to one OS; use `ios { }`/`android { }` when
only a few steps inside an otherwise-shared scenario differ.

### Link
- [index](../index.md)
