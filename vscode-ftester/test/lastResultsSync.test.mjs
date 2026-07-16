// lastResultsSync.test.mjs
// diffLastResults(vscode 非依存の純粋関数)の回帰テスト。registerLastResultsSync 本体は
// vscode.TestController 等が要るためテスト対象外(runHandler.test.mjs 冒頭コメント参照)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { diffLastResults } from "../src/lastResultsSync";

test("diffLastResults: previous が空なら current の全件を報告する", () => {
  const current = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const changed = diffLastResults(current, new Map());
  assert.deepEqual(
    changed.sort((a, b) => a.id.localeCompare(b.id)),
    [
      { id: "A.s1", state: "passed" },
      { id: "A.s2", state: "failed" },
    ],
  );
});

test("diffLastResults: current と previous が同一なら空", () => {
  const snapshot = new Map([["A.s1", "passed"]]);
  assert.deepEqual(diffLastResults(snapshot, new Map(snapshot)), []);
});

test("diffLastResults: 状態が変わった id のみ報告する", () => {
  const previous = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const current = new Map([
    ["A.s1", "passed"],
    ["A.s2", "passed"],
  ]);
  assert.deepEqual(diffLastResults(current, previous), [{ id: "A.s2", state: "passed" }]);
});

test("diffLastResults: previous にあり current に無い id は報告しない", () => {
  const previous = new Map([
    ["A.s1", "passed"],
    ["A.s2", "failed"],
  ]);
  const current = new Map([["A.s1", "passed"]]);
  assert.deepEqual(diffLastResults(current, previous), []);
});
