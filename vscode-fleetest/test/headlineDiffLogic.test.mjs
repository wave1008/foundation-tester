// headlineDiffLogic.test.mjs
// 前回比の判定を持つ純関数(headlineDiffLogic.js)の単体テスト。DOM に触れないので
// jsdom は要らない(dashboardFormatSeconds.test.mjs と同じ方式)。

import assert from "node:assert/strict";
import { test } from "node:test";

import { computeHeadlineDiff, selectComparisonGroups } from "../src/webview/dashboard/headlineDiffLogic.js";

function run(overrides = {}) {
  return {
    runID: "R1",
    runGroup: undefined,
    profile: "ios-inapp",
    host: "H",
    startedAt: "2026-09-26T00:00:00Z",
    total: 10,
    passed: 9,
    failed: 1,
    ...overrides,
  };
}

test("selectComparisonGroups: 同じ profile で全構成 run が完了している直前のグループを返す", () => {
  const groups = [
    [run({ runID: "R2", profile: "ios-inapp" })],
    [run({ runID: "R1", profile: "ios-inapp" })],
  ];
  const result = selectComparisonGroups(groups);
  assert.deepEqual(result.latest, groups[0]);
  assert.deepEqual(result.previous, groups[1]);
});

test("selectComparisonGroups: profile が違うグループはスキップして次を見る", () => {
  const groups = [
    [run({ runID: "R3", profile: "ios-inapp" })],
    [run({ runID: "R2", profile: "android" })],
    [run({ runID: "R1", profile: "ios-inapp" })],
  ];
  const result = selectComparisonGroups(groups);
  assert.equal(result.previous[0].runID, "R1");
});

test("selectComparisonGroups: 構成 run の集計が1本でも未完了なら候補から外す", () => {
  const groups = [
    [run({ runID: "R2", profile: "ios-inapp" })],
    [run({ runID: "R1a", profile: "ios-inapp" }), run({ runID: "R1b", profile: "ios-inapp", total: null, passed: null, failed: null })],
  ];
  const result = selectComparisonGroups(groups);
  assert.equal(result, null);
});

test("selectComparisonGroups: 比較相手が無ければ null(グループ1個・全部 profile 不一致・全部未完了)", () => {
  assert.equal(selectComparisonGroups([]), null);
  assert.equal(selectComparisonGroups([[run()]]), null);
  assert.equal(
    selectComparisonGroups([[run({ profile: "ios-inapp" })], [run({ profile: "android" })]]),
    null,
  );
});

function scenario(overrides = {}) {
  return {
    runID: "R1",
    scenarioID: "Login.S0010",
    platform: "ios",
    host: "H",
    passed: true,
    startedAt: "2026-09-26T00:00:00Z",
    durationMs: 100,
    scenes: [],
    steps: { total: 1, passed: 1, failed: 0, skipped: 0, healed: 0, passedViaFallback: 0 },
    ...overrides,
  };
}

function runPayload(scenarios) {
  return { schemaVersion: 1, project: "P", run: { runID: "R", project: "P", host: "H", trigger: "cli", startedAt: "" }, scenarios };
}

test("computeHeadlineDiff: 最新で失敗・前回で成功 = 新規失敗", () => {
  const latest = [runPayload([scenario({ scenarioID: "A", platform: "ios", passed: false })])];
  const previous = [runPayload([scenario({ scenarioID: "A", platform: "ios", passed: true })])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff.newFailures, [{ scenarioID: "A", platform: "ios" }]);
  assert.deepEqual(diff.recovered, []);
});

test("computeHeadlineDiff: 最新で成功・前回で失敗 = 回復", () => {
  const latest = [runPayload([scenario({ scenarioID: "A", platform: "ios", passed: true })])];
  const previous = [runPayload([scenario({ scenarioID: "A", platform: "ios", passed: false })])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff.recovered, [{ scenarioID: "A", platform: "ios" }]);
  assert.deepEqual(diff.newFailures, []);
});

test("computeHeadlineDiff: 両方同じ結果なら差分に出さない", () => {
  const latest = [runPayload([scenario({ scenarioID: "A", passed: true })])];
  const previous = [runPayload([scenario({ scenarioID: "A", passed: true })])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff, { newFailures: [], recovered: [] });
});

test("computeHeadlineDiff: (scenarioID, platform) の組で突き合わせる(同じ scenarioID でも platform が違えば別)", () => {
  const latest = [runPayload([scenario({ scenarioID: "A", platform: "android", passed: false })])];
  const previous = [runPayload([scenario({ scenarioID: "A", platform: "ios", passed: true })])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff, { newFailures: [], recovered: [] });
});

test("computeHeadlineDiff: skipKind のある記録は比較から外す", () => {
  const latest = [runPayload([scenario({ scenarioID: "A", passed: false, skipKind: "interrupted" })])];
  const previous = [runPayload([scenario({ scenarioID: "A", passed: true })])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff, { newFailures: [], recovered: [] });
});

test("computeHeadlineDiff: 比較相手のいないシナリオは無視する", () => {
  const latest = [runPayload([scenario({ scenarioID: "New", passed: false })])];
  const previous = [runPayload([])];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff, { newFailures: [], recovered: [] });
});

test("computeHeadlineDiff: フリート実行(構成 run 複数)は全部のシナリオを1枚に畳んで突き合わせる", () => {
  const latest = [
    runPayload([scenario({ scenarioID: "A", platform: "ios", passed: false })]),
    runPayload([scenario({ scenarioID: "B", platform: "android", passed: true })]),
  ];
  const previous = [
    runPayload([scenario({ scenarioID: "A", platform: "ios", passed: true })]),
    runPayload([scenario({ scenarioID: "B", platform: "android", passed: false })]),
  ];
  const diff = computeHeadlineDiff(latest, previous);
  assert.deepEqual(diff.newFailures, [{ scenarioID: "A", platform: "ios" }]);
  assert.deepEqual(diff.recovered, [{ scenarioID: "B", platform: "android" }]);
});

test("computeHeadlineDiff: 同じ (scenarioID, platform) が複数あれば1件でも失敗なら失敗(読んだ順に依らない)", () => {
  const previous = [runPayload([scenario({ scenarioID: "A", passed: true })])];
  for (const order of [[false, true], [true, false]]) {
    const latest = [runPayload(order.map((passed) => scenario({ scenarioID: "A", passed })))];
    assert.deepEqual(computeHeadlineDiff(latest, previous).newFailures, [{ scenarioID: "A", platform: "ios" }]);
  }
  const latestAllPass = [runPayload([scenario({ scenarioID: "A", passed: true })])];
  const previousMixed = [runPayload([scenario({ scenarioID: "A", passed: false }), scenario({ scenarioID: "A", passed: true })])];
  assert.deepEqual(computeHeadlineDiff(latestAllPass, previousMixed).recovered, [{ scenarioID: "A", platform: "ios" }]);
});
