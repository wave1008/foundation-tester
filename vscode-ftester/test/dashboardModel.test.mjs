// dashboardModel.test.mjs
// dashboardModel.ts(isApiResultsPayload/isDashboardFromWebviewMessage)のユニットテスト。
// node:test で実行する。esbuild が "../src/dashboardModel"(拡張子なし)を dashboardModel.ts に
// 解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { isApiResultsPayload, isDashboardFromWebviewMessage } from "../src/dashboardModel";

function validPayload(overrides = {}) {
  return {
    schemaVersion: 1,
    project: "SampleApp",
    generatedAt: "2026-07-16T00:00:00Z",
    since: "2026-04-17T00:00:00Z",
    runs: [
      {
        schemaVersion: 1,
        runID: "20260716-000000",
        project: "SampleApp",
        profile: "default",
        machine: "M2 Ultra",
        trigger: "cli",
        startedAt: "2026-07-16T00:00:00Z",
        finishedAt: "2026-07-16T00:05:00Z",
        total: 10,
        passed: 9,
        failed: 1,
      },
    ],
    summary: [
      { scenarioID: "Login", runs: 5, successRate: 80.0, avgDurationMs: 1200, medianDurationMs: 1100, lastRunAt: "2026-07-16T00:00:00Z", lastPassed: true },
    ],
    flaky: [
      { scenarioID: "Checkout", runs: 8, failureRate: 25.0, flakinessScore: 0.42, recentResults: [true, false, true, true] },
    ],
    devices: {
      byWorker: [{ worker: "ios:iPhone 15", runs: 10, successRate: 90.0, avgDurationMs: 1500 }],
      byPlatform: [{ platform: "ios", runs: 10, successRate: 90.0, avgDurationMs: 1500 }],
    },
    daily: [{ date: "2026-07-16", total: 10, passed: 9, failed: 1 }],
    ...overrides,
  };
}

test("isApiResultsPayload: 契約通りの完全な値を true と判定する", () => {
  assert.equal(isApiResultsPayload(validPayload()), true);
});

test("isApiResultsPayload: trend を含む値(--scenario 指定時相当)も true と判定する", () => {
  const payload = validPayload({
    trend: [
      {
        runID: "20260716-000000",
        scenarioID: "Login",
        platform: "ios",
        worker: "ios:iPhone 15",
        machine: "M2 Ultra",
        passed: true,
        startedAt: "2026-07-16T00:00:00Z",
        durationMs: 1200,
        scenes: [],
        steps: { total: 3, passed: 3, failed: 0, skipped: 0, healed: 0, passedViaFallback: 0 },
      },
    ],
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: Codable の nil Optional 省略(profile/finishedAt/total 等が欠落)を許容する", () => {
  const payload = validPayload();
  payload.runs = [
    {
      schemaVersion: 1,
      runID: "20260716-000000",
      project: "SampleApp",
      machine: "M2 Ultra",
      trigger: "api",
      startedAt: "2026-07-16T00:00:00Z",
      // profile/finishedAt/total/passed/failed は省略(未完了 run 相当)
    },
  ];
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: null で明示されたオプショナルも許容する", () => {
  const payload = validPayload();
  payload.runs[0].profile = null;
  payload.runs[0].finishedAt = null;
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: slow/insights を含む完全な値も true と判定する", () => {
  const payload = validPayload({
    slow: [
      {
        scenarioID: "Checkout",
        runs: 12,
        avgDurationMs: 8300.5,
        p90DurationMs: 12000.0,
        deltaPct: 42.1,
        slowestScene: "ログイン画面",
        slowestSceneAvgMs: 4100.0,
      },
      // deltaPct/slowestScene/slowestSceneAvgMs 省略(4回未満・該当なし相当)
      { scenarioID: "Login", runs: 3, avgDurationMs: 900.0, p90DurationMs: 1200.0 },
    ],
    insights: [
      { kind: "newFailure", severity: "critical", scenarioID: "Checkout", message: "新規失敗が発生しました" },
      { kind: "deviceBias", severity: "warn", worker: "android:Pixel 8", message: "特定端末で失敗率が高い", count: 3 },
      { kind: "durationRegression", severity: "info", scenarioID: "Login", message: "所要時間が悪化", deltaPct: 20.5 },
    ],
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: slow/insights が欠落(旧 CLI 相当)でも true と判定する", () => {
  const payload = validPayload();
  delete payload.slow;
  delete payload.insights;
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: slow の必須フィールド欠落は false", () => {
  const payload = validPayload({ slow: [{ scenarioID: "Checkout", runs: 12, avgDurationMs: 8300.5 }] });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: insights の kind/severity が不正な値なら false", () => {
  const badKind = validPayload({ insights: [{ kind: "unknown", severity: "critical", message: "x" }] });
  assert.equal(isApiResultsPayload(badKind), false);
  const badSeverity = validPayload({ insights: [{ kind: "newFailure", severity: "unknown", message: "x" }] });
  assert.equal(isApiResultsPayload(badSeverity), false);
});

test("isApiResultsPayload: slow/insights が配列でなければ false", () => {
  assert.equal(isApiResultsPayload(validPayload({ slow: "not-an-array" })), false);
  assert.equal(isApiResultsPayload(validPayload({ insights: "not-an-array" })), false);
});

test("isApiResultsPayload: 値が object でなければ false", () => {
  assert.equal(isApiResultsPayload(null), false);
  assert.equal(isApiResultsPayload("not json"), false);
  assert.equal(isApiResultsPayload(42), false);
});

test("isApiResultsPayload: schemaVersion 欠落は false", () => {
  const payload = validPayload();
  delete payload.schemaVersion;
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: runs が配列でなければ false", () => {
  const payload = validPayload({ runs: "not-an-array" });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: runs 内の必須フィールド欠落は false", () => {
  const payload = validPayload();
  delete payload.runs[0].machine;
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: flaky.recentResults が boolean[] でなければ false", () => {
  const payload = validPayload();
  payload.flaky[0].recentResults = ["true", "false"];
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: devices.byWorker/byPlatform の必須フィールド欠落は false", () => {
  const payload = validPayload();
  delete payload.devices.byWorker[0].successRate;
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: devices が欠落していれば false", () => {
  const payload = validPayload();
  delete payload.devices;
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: daily の必須フィールド欠落は false", () => {
  const payload = validPayload({ daily: [{ date: "2026-07-16", total: 10, passed: 9 }] });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: 空配列群(0件実行相当)は true", () => {
  const payload = validPayload({
    runs: [],
    summary: [],
    flaky: [],
    devices: { byWorker: [], byPlatform: [] },
    daily: [],
  });
  assert.equal(isApiResultsPayload(payload), true);
});

// ---- isDashboardFromWebviewMessage --------------------------------------------------

test("isDashboardFromWebviewMessage: ready/refresh を true と判定する", () => {
  assert.equal(isDashboardFromWebviewMessage({ type: "ready" }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "refresh" }), true);
});

test("isDashboardFromWebviewMessage: 未知の type/非object は false", () => {
  assert.equal(isDashboardFromWebviewMessage({ type: "unknown" }), false);
  assert.equal(isDashboardFromWebviewMessage(null), false);
  assert.equal(isDashboardFromWebviewMessage("ready"), false);
  assert.equal(isDashboardFromWebviewMessage(undefined), false);
});
