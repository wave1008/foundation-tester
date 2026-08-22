# dry-run

`ftester run --dry-run` (Shirates' No-Load-Run equivalent) enumerates and validates a scenario's
steps **without touching a device or calling FM**. It catches mistakes that would otherwise only
surface during, or after, a slow device run — in seconds.

```bash
ftester run --dry-run --scenario ログインテスト
```

MCP exposes the same check as `ft_dry_run`; the VS Code extension runs it via
`ftester api run --dry-run` (the Test Explorer's "Run (dry-run)" action).

## What it catches

| Problem | How it's caught |
|---|---|
| Selector syntax errors | The selector expression parser runs before any device call |
| Unreachable scenes / branches | Static reachability check of the scenario structure |
| An `expectation { }` block with zero assertions | Counted the same way `verify` counts assertions (`exist`/`notExist`/`textIs` and friends, `thisIs` variants, `appIs`; `select` does not count). A scenario with **zero** assertions overall gets a stronger warning |
| `#id`s that don't exist in any screen you've captured | Checked against the project's selector inventory (`<project>/.ftester/selector-inventory.json`), built by `ft_snapshot` calls made while writing the scenario |

Notes on the last check: it only warns about screens you have actually captured — if the
inventory has no record for a given screen (or platform), dry-run stays silent rather than
guessing. It also stays silent while the inventory is thin: the warning only fires when at least
two thirds of a scenario's `#id`s are already in the inventory (a single captured screen would
otherwise flag most existing scenarios as wrong). Only exact-match `#id`s are checked — wildcard
forms (`#row_*`) and labels are excluded, since labels normally change with copy edits.

None of this is caught for content inside `ios { }` / `android { }` / `ifCanSelect { }` blocks
that never executed for the platform being checked — what's inside is only known once the block
actually runs.

## What it does not do

- It never contacts a device or an emulator/simulator, and never calls FM.
- `--profile` is not used, since no device is involved — only `--platform` decides which of
  `ios { }` / `android { }` to check.
- It does not write a report, and its result is not recorded for `--failed` to pick up later.

`--scenario` / `--folder` / `--project` / `--quiet` all work the same as a normal run, and a
failed check sets exit code `1` — so `ftester run --dry-run` (with no `--scenario`) is a cheap
gate to run before every device run across a whole project.

### Link
- [index](../index.md)
