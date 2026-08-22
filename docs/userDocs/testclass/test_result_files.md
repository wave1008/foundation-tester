# What a Run Produces

Every run — pass or fail — leaves several kinds of output behind. This page is a map of
where to find them; see [Results analysis](../running/results_analysis.md) and
[Result JSON schema](../../results-json.md) for detail.

## Markdown report

`TestProjects/<project>/reports/scenario-*.md` — one report per scenario run, written
regardless of outcome. It has the same hierarchy as the code:
`scene → condition/action/expectation → step`, plus a triage summary, a screenshot of the
point of failure (if any), and fix suggestions for a broken selector when self-healing ran.

## Result JSON

`results/runs/<YYYY-MM>/<runID>/` holds the machine-readable record: `run.json` for the
whole run and `scenarios/<scenarioID>.json` per scenario. This is the source used for CI
gating, dashboards, and scripted triage. Full field reference:
[Result JSON schema](../../results-json.md).

## JUnit XML

`ftester run --junit <path>` additionally writes a JUnit XML file, for CI systems that
consume that format directly.

## Video recordings

Setting `record: true` in the run profile records each device for the whole run and slices
out one clip per scenario into `<runDir>/recordings/`. A failing run doesn't lose the video
— recording failures don't fail the run itself.

## Self-healing cache

When self-healing is on, `TestProjects/<project>/.ftester/heal-cache.json` stores selectors
that were repaired at runtime, so the second run onward is deterministic (no AI needed) even
though the source still has the old selector. See
[Self-healing](../running/self_healing.md).

## Last-run results (for `--failed`)

`.ftester/last-results/<project>/` records which scenarios passed or failed on the most
recent run, so `ftester run --failed` can re-run just the failures.

## From the VS Code extension

The extension's Test Explorer shows pass/fail per test and can open the generated Markdown
report directly ("Open Report").

### Link
- [index](../index.md)
