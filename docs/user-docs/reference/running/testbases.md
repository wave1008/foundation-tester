# Test bases and scenario drafts (draft-scenario)

[in Japanese(日本語)](testbases_ja.md)

A **test base** is a Markdown file holding the specification, test viewpoints or source material that scenarios are based on.
`fleetest draft-scenario` reads a test base and produces a **draft** Swift scenario with the skeleton of `scene`s (condition,
action, expectation). Selectors cannot be decided from text, so every one comes out as a `#TODO` placeholder. A person or an AI
assistant then captures the real selectors from the live screen, replaces the placeholders, and removes `@Draft` when it works.

## Putting a test base in place

The location is `TestProjects/<project>/docs/testbases/` (the folder is created by
[Creating a Test Project](../project/creating_project.md)). Put SC / TC specifications, test viewpoint tables or notes on the
original requirements there as Markdown; they are the basis for having an AI assistant write scenarios.
The `README.md` in that folder describes the place and does not count as a test base.

`draft-scenario` reads these files:

- Files with the extension `.md`, `.markdown` or `.txt`. `--testbase <path>` can also point at a file outside the folder.
- Without `--testbase`, it uses the file only when `docs/testbases/` has **exactly one** test base. With none it is an error;
  with several it lists the candidates and stops, so choose one with `--testbase`.

## Format

Write it so that headings and bullets are enough to read it. These are the only rules.

| What you write | How it is read |
|---|---|
| The first `#` heading | The description of the scenario (`@Test`); also the source of the class name. The file name if there is none |
| `##` headings | One `scene` each. If there is no `##` at all, the whole file is one `scene` |
| `###` and deeper headings | Switch which bucket (condition, action, expectation) the following lines go to (a heading matching none of the keywords below keeps the current bucket) |
| Bullet, numbered or checkbox lines | One step each (a leading `-` `*` `+` `>`, `1.` `1)` and `[ ]` `[x]` are stripped) |
| A leading label such as `Given:` `When:` `Then:` | Sets the bucket of that line (the colon may also be the full-width one) |
| A line with no label | Goes to the current bucket (initially action). A line that ends with the Japanese nominalizer "koto" (the usual way of writing a test viewpoint in Japanese) goes to expectation |

The bucket (condition, action, expectation) is decided by whether the heading or the leading label contains one of these
keywords (Latin letters are case-insensitive). The Japanese keywords are listed in the Japanese version of this page.

| Bucket | Keywords |
|---|---|
| Condition (`condition`) | `given`, `setup` (plus Japanese words for precondition, condition, in advance and preparation) |
| Action (`action`) | `when`, `action` (plus Japanese words for operation, procedure, execute and step) |
| Expectation (`expectation`) | `then`, `expect` (plus Japanese words for expectation, check, result, verification and viewpoint) |

A leading label is stripped only when it is at most 12 characters and matches one of these keywords. A colon inside the text,
such as "Error: connection failed", matches no keyword and is left as it is. Emphasis marks (`**`, `__`) and inline-code backticks
are removed.

```markdown
# Login

## Logging in with correct credentials works

- Given: the app is launched
- When: enter the email address
- When: enter the password
- When: tap the login button
- Then: the home screen is shown

## A wrong password shows an error

### Steps
1. Log in with a wrong password

### Checks
- an error message is shown
- the login button can be pressed
```

## Generating a draft

```bash
fleetest draft-scenario --project SampleApp --testbase docs/testbases/login.md
```

| Option | Description |
|---|---|
| `--project <project>` | Test project name (defaults to the only one in `TestProjects/`, or the default project) |
| `--testbase <path>` | Path to the test base file (defaults to the only file in the project `docs/testbases/`) |
| `--name <name>` | Name of the generated test class (defaults to one derived from the test base heading) |
| `--platform <ios\|android>` | Target platform (defaults to both). When given, it is written to `@TestClass(platform:)` |
| `--no-fm` | Structure the draft from the Markdown headings and bullets alone, without Foundation Models |
| `--dry-run` | Print the generated code to stdout instead of writing a file |

By default the structuring is done by Foundation Models (FM, which runs on the device only). When FM is unavailable or cannot
structure the text, it falls back automatically to the mechanical reading of the format above. Only the **first 2400 characters**
of the test base go to FM, and a warning is printed when the file is longer (the rest is not reflected in the draft; split the
file or use `--no-fm`). If you wrote the file in the format above, `--no-fm` is enough and gives the same result every time.

The result is written to `TestProjects/<project>/scenarios/Drafts/<ClassName>.swift` and then checked by a build. Code that does
not build is moved to `scenarios/_disabled/`, so the rest of the suite is not dragged down.
If you give `--name` and a draft of that name already exists, the command stops with an error instead of overwriting it.

## The output and `@Draft`

The generated class carries `@Draft`.

- `@Draft` marks work in progress. **It stays in the list as "work in progress"** and is **excluded** from full runs, folder runs
  and runs by class name. **It runs only when you give an exact ID** (`--scenario <Class>.<method>`), which is the way to run it on
  its own while you finish it.
- Selectors come out as `#TODO`. `#TODO` is an id that can never be resolved, so if you forget to replace one and remove
  `@Draft`, the scenario **always fails with "cannot resolve the locator"** (this is intended: failing is better than going green
  on an empty implementation).
- The text of each step is always kept as a trailing comment on the command line, so the original intent stays readable even when
  the mapping to a command is off.

Step text is mapped to a command template by simple keyword matching (a rough guide that you finish by hand).

| Bucket | Words in the text | Template |
|---|---|---|
| Condition | `launch`, or the Japanese words for launch / start up; or both "app" and "open"/"show" | `launchApp()` (any other condition becomes only a `// TODO` comment) |
| Action | `type`, or the Japanese words for enter / fill in / key in | `type("#TODO", "TODO")` |
| Action | the Japanese words for long press / long tap | `tap("#TODO", holdSeconds: 1)` |
| Action | `scroll`, `swipe`, or their Japanese equivalents | `scrollTo("#TODO")` |
| Action | restart / launch / wait (`launch`, `wait`, or the Japanese words for restart, launch and wait) | `restartApp()` / `launchApp()` / `wait(1)` |
| Action | none of the above | `tap("#TODO")` |
| Expectation | the Japanese words for "is not shown", "disappears", "closes", "hidden" and similar | `notExist("#TODO")` |
| Expectation | `disabled` or the Japanese words for "cannot be pressed" / `enabled` or "can be pressed" | `select("#TODO").enabledIsFalse()` / `enabledIsTrue()` |
| Expectation | a count such as "3 items" written with the Japanese counters for items, pieces, rows or entries | `countIs("#TODO", 3)` |
| Expectation | the Japanese words for "is displayed as", "wording" and "message" | `select("#TODO").textIs("TODO")` |
| Expectation | none of the above | `exist("#TODO")` |

In the first `scene`, `launchApp()` is added when the condition has no launch.

### Finishing a draft

1. Open the draft and capture the real selectors on the live screen, `scene` by `scene`. If you ask an AI assistant, it reads the
   current screen with `ft_snapshot` and replaces the `#TODO`s ([Agent Guide](../tools/agent_guide.md)).
2. Check the selector syntax and so on with `--dry-run` ([dry-run](./dry_run.md)), then run it on a device. While `@Draft` is on,
   run it by exact ID.
3. When it passes, delete the `@Draft(...)` line of the class. From then on it is part of the full runs.

## What to tell the AI assistant

Once the test base is in place, ask like this ([Basics of using fleetest](../../tutorial/basic_usage.md)).

```text
Use docs/testbases/login.md as the test base and create a scenario draft with fleetest draft-scenario.
Then operate the real app, replace the #TODO selectors with real ones, and make it run and pass. When it passes, remove @Draft.
```

```text
Write an iOS scenario based on the specification in docs/testbases. Where the app does not behave as specified,
do not bend the test to the actual behaviour to make it green: keep the specified expectation so that it fails,
and record the issue as a defect.
```

An AI assistant can also read the specification directly and write a scenario without a draft. `draft-scenario` is the entry point
for when you want a mechanical skeleton first and finish it afterwards. Note that the MCP `ft_draft_scenario` is a different
thing: it returns the operations you performed while exploring as a Swift scenario ([MCP Server](../tools/mcp_server.md)).

## When a specification violation is found

When scenarios are written from a test base, you may find places where the app does not follow the specification.
The standard handling in the AI assistant skill (`/fleetest-scenario`) is as follows.

- **A specification violation is not turned green.** Bending the test to the actual behaviour to make it pass would hide the
  violation behind a green result, and a regression could no longer be detected. **Keep the specified expectation so that the
  scenario fails (red) and track it.** Put the cleanup in `afterEach` (a failure aborts the scenario, but `afterEach` still runs
  after a failure, so nothing is left behind).
- **Record each defect in its own file under `TestProjects/<project>/issues/defects/`.** The naming, template and legend are in
  the `README.md` of that folder (file names are `D-<2-digit number>-<slug>.md`), and the status of every defect is collected in
  the `INDEX.md` of the same folder (a dashboard of the handling status). When you file a defect or change a status, update both
  the individual file and `INDEX.md` (including its totals). Each file records the target, the related SC / TC, the severity, the
  status, the scenario that detected it, the steps to reproduce, the expected result, the actual result, the evidence and a proposed
  ruling on the specification.
- **The test does not decide on its own which side is right.** When a TC itself says to record the actual behaviour as a pass and
  to file the ruling on the specification separately (for example when the specification and the implementation disagree), follow
  that instruction: keep it green and hand the matter to the defect side as something that needs a ruling.
- When a defect is fixed, update its status and check that the corresponding test turns green.

### Link
- [index](../../index.md)
