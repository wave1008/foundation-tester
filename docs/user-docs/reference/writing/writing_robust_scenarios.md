# Writing Robust Scenarios

[in Japanese(日本語)](writing_robust_scenarios_ja.md)

Conventions that keep scenarios from becoming flaky or silently useless. Full details of each command
are in the per-command pages listed in the [index](../../index.md).

## Don't add `wait` for element appearance

Element appearance is waited for implicitly: operations retry locator resolution for about 0.7s
(`waitSeconds:` to change it), and verification commands poll until their timeout (5s by default).
Putting a `wait(1)` before `exist(...)` is redundant — if the wait isn't long enough, raise the
command's own `waitSeconds:` instead. `wait` still has a real use: waiting out an animation where the
element already exists but its tap coordinates are still moving (a menu expanding, a sheet
sliding in).

## Take selectors from a real screenshot, not from memory

Never guess an id or label. Capture the real screen (with `ft_snapshot`, or the VSCode
extension's device monitor, Live Control tab) and copy the id/label/type it actually reports. Prefer `#id`
first — it's the most durable. Where an id isn't available, add a label as a fallback with `||`:

```swift
tap("#login_btn||Log In")   // tries #login_btn first, falls back to the label
```

`||` is a union of candidates: `tap` lands on whichever is found first, so this also serves as a
self-healing fallback chain.

## Don't leave coordinate taps in a scenario

`tap(x:y:)` is for the rare screen that exposes no operable elements at all. Once you've found a
selector, use it — coordinates break the instant the layout shifts, while a selector survives
minor UI changes. Coordinates are fine for a one-off exploratory operation (in MCP use, for
example) that won't be run again, but a scenario is replayed repeatedly, so this is where the
distinction matters most.

## Wrap anything that may or may not appear

There's no "might not exist" argument on any command — an unresolved selector always fails the
scenario. For a dialog or banner that only sometimes appears, wrap the check:

```swift
ifCanSelect("Not Now", waitSeconds: 2) {
    tap("Not Now")
}
```

For an in-app message that can appear at any point during a scene (a promo modal, for example),
declare an `irregularHandler` once in `beforeEach()` instead of guarding every step — it closes the
message automatically wherever it shows up. (OS-level system dialogs, like iOS permission
prompts, are handled separately — see `iosAlertHandler` — since they live outside the app's own
element tree.)

## Always put an assertion in `expectation`

An `expectation { }` block with no assertion in it compiles and runs fine, but proves nothing —
the scenario stays green no matter how the app breaks. `screenLooksLike` does not count as an assertion (it is
a rough check whose result can flip with the wording or with how the screen was captured). `fleetest run --dry-run` catches this
before you ever touch a device: it flags any `expectation` block with zero assertions, and any
`#id` that doesn't appear in a screen you've actually captured with `ft_snapshot`. Always run
dry-run once after writing a scenario, before running it on a device.

## Failure aborts the whole scenario — `afterEach` still runs

A failing command stops the scenario immediately; every later step, including later scenes, is
skipped. The one exception is `afterEach()`, which always runs even after a failure — put cleanup
there (deleting data your scenario created, for example) so a failed run doesn't leave state
behind for the next run.

## Don't pin `platform:` if the scenario should run on both OS

`@TestClass` takes no `app:` — the target app always comes from the active run profile. Leaving
`platform:` unset lets the same scenario run against both `--profile ios-run` and
`--profile android-run`. Only set it when a scenario is genuinely OS-specific (a platform-only
setting screen, for instance) — otherwise you'd need to duplicate the class per OS.

## Read a value before it can change

A value read from an element (`exist("#total").text`, `.value`, `.id`) is a snapshot taken at the
moment you read it — it is not re-fetched later. If the screen is still updating, confirm it has
settled (with `textIs` or similar) before reading, or you'll capture a value mid-update.

## Never retry an irreversible action

If an interruption appears while an operation's effect is still landing, the tool does not
re-send it — whether the tap already registered can't be observed, and resending it could
double-fire. A scenario may re-attempt this itself after confirming where it landed (`ifCanSelect`
to check the resulting screen, then tap again), but **only for an action that's safe to repeat**.
Never write a retry around something irreversible — submitting a form, confirming a purchase, and
the like.

## Write every scenario to survive being re-run from the start

A scenario that fails because of the device (a freeze, a lost bridge connection) is **run again from the start**
within the run, not necessarily on the same device. On a device whose display is confirmed to have frozen, the
scenario that passed just before is run again too. This cannot be turned off, so write each scenario so that
**running it again from the start still passes**.

- Create the starting state yourself (start from `clearAppData()` or a logout; don't rely on what an earlier run left)
- Use different values for the data you create on every run (so a second sign-up with the same email does not fail)
- Point operations that cannot be undone, such as sending or purchasing, at an environment where receiving them twice
  does no harm (test payments, a staging server)

### Link
- [index](../../index.md)
