// healModel.test.mjs
// healModel.ts(HealFixCollector・countDistinctFixes)のユニットテスト。
// node:test で実行する。esbuild が "../src/healModel"(拡張子なし)を healModel.ts に解決して
// バンドルする。
//
// 末尾に、mock-runner.mjs(--pattern heal)を実際に spawn して NdjsonParser → HealFixCollector に
// 通す統合テストを1本含む(healNotice.ts が RunEventBus 経由で行う配線の縮小版。
// runReducer.test.mjs の mock-runner 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import { countDistinctFixes, HealFixCollector } from "../src/healModel";

const MOCK_RUNNER = path.resolve(process.cwd(), "test", "fixtures", "mock-runner.mjs");

// ---- HealFixCollector ----------------------------------------------------------------

test("HealFixCollector: fixSuggestion を収集し、必須フィールドが揃った HealFix を返す", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    description: 'tap "#old_id"',
    detail: "ロケータが変化した可能性があります",
    file: "TestProjects/P/scenarios/S.swift",
    line: 12,
    oldSelector: "#old_id",
    newSelector: "#new_id",
  });
  const list = collector.list();
  assert.equal(list.length, 1);
  assert.deepEqual(list[0], {
    scenarioID: "S.T1",
    file: "TestProjects/P/scenarios/S.swift",
    line: 12,
    oldSelector: "#old_id",
    newSelector: "#new_id",
    message: "ロケータが変化した可能性があります",
    command: 'tap "#old_id"',
  });
});

test("HealFixCollector: message は detail が無ければ description、どちらも無ければ空文字列", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    description: 'tap "#old_id"',
    file: "a.swift",
    line: 1,
    oldSelector: "#old_id",
    newSelector: "#new_id",
  });
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T2",
    file: "a.swift",
    line: 2,
    oldSelector: "#old2",
    newSelector: "#new2",
  });
  const byScenario = Object.fromEntries(collector.list().map((f) => [f.scenarioID, f]));
  assert.equal(byScenario["S.T1"].message, 'tap "#old_id"');
  assert.equal(byScenario["S.T2"].message, "");
});

test("HealFixCollector: scenario/file/line/oldSelector/newSelector のいずれかが欠けるイベントは無視する", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  const base = {
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  };
  for (const key of ["scenario", "file", "line", "oldSelector", "newSelector"]) {
    const event = { ...base };
    delete event[key];
    collector.collect(event);
  }
  assert.equal(collector.list().length, 0);
});

test("HealFixCollector: 同一id(scenario/file/line/oldSelector が同一)は重複排除し、後勝ちで上書きする", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  const base = { kind: "fixSuggestion", scenario: "S.T1", file: "a.swift", line: 1, oldSelector: "#old" };
  collector.collect({ ...base, newSelector: "#new1", detail: "1回目" });
  collector.collect({ ...base, newSelector: "#new2", detail: "2回目" });
  const list = collector.list();
  assert.equal(list.length, 1);
  assert.equal(list[0].newSelector, "#new2");
  assert.equal(list[0].message, "2回目");
});

test("HealFixCollector: begin(true)(dry-run)の間は collect() が候補を積まない", () => {
  const collector = new HealFixCollector();
  collector.begin(true);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  });
  assert.equal(collector.isEmpty(), true);
});

test("HealFixCollector: begin() を呼ぶと前回までの候補がクリアされる", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  });
  assert.equal(collector.isEmpty(), false);
  collector.begin(false);
  assert.equal(collector.isEmpty(), true);
});

test("HealFixCollector: fixSuggestion 以外の kind は無視する", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({ kind: "step", scenario: "S.T1", status: "passed" });
  assert.equal(collector.isEmpty(), true);
});

// ---- countDistinctFixes ---------------------------------------------------------------

const fix = (over) => ({ scenarioID: "S.T1", file: "a.swift", line: 1, oldSelector: "#o", newSelector: "#n", message: "", command: undefined, ...over });

test("countDistinctFixes: file・line・旧・新セレクタが同じものは1件(シナリオ違いでも)", () => {
  assert.equal(countDistinctFixes([fix({}), fix({ scenarioID: "S.T2" })]), 1);
});

test("countDistinctFixes: line・旧・新セレクタ・file のどれかが違えば別件、空なら 0", () => {
  assert.equal(countDistinctFixes([fix({}), fix({ line: 2 }), fix({ oldSelector: "#p" }), fix({ newSelector: "#m" }), fix({ file: "b.swift" })]), 5);
  assert.equal(countDistinctFixes([]), 0);
});

// ---- 統合: mock-runner.mjs(heal パターン)→ NdjsonParser → HealFixCollector -----------------

test("統合: mock-runner.mjs(heal パターン)の出力から、重複排除された1件の候補が収集される", async () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  await runMockThroughCollector(collector, ["--pattern", "heal", "--scenario", "統合.HealT1"]);

  const list = collector.list();
  assert.equal(list.length, 1);
  assert.equal(list[0].scenarioID, "統合.HealT1");
  assert.equal(list[0].oldSelector, "#old_id");
  assert.equal(list[0].newSelector, "#new_id");
  // 2件目(後勝ち)の detail が残る
  assert.match(list[0].message, /2回目/);
});

test("統合: mock-runner.mjs(heal パターン)でも begin(true)(dry-run)なら候補が収集されない", async () => {
  const collector = new HealFixCollector();
  collector.begin(true);
  await runMockThroughCollector(collector, ["--pattern", "heal", "--scenario", "統合.HealT2"]);

  assert.equal(collector.isEmpty(), true);
});

/**
 * mock-runner.mjs を spawn し、stdout を NdjsonParser に通して RunEvent を collector.collect() へ
 * 渡す(healNotice.ts が RunEventBus 経由で行う配線の縮小版)。
 */
function runMockThroughCollector(collector, mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_RUNNER, ...mockArgs], {
      cwd: path.dirname(MOCK_RUNNER),
      stdio: ["ignore", "pipe", "pipe"],
    });

    const parser = new NdjsonParser(
      (value) => {
        if (value && typeof value === "object" && typeof value.kind === "string") {
          collector.collect(value);
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", reject);
    proc.on("close", () => {
      parser.end();
      resolve();
    });
  });
}
