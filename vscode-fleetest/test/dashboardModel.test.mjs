// dashboardModel.test.mjs
// dashboardModel.ts(isApiResultsPayload/isDashboardFromWebviewMessage)のユニットテスト。
// node:test で実行する。esbuild が "../src/dashboardModel"(拡張子なし)を dashboardModel.ts に
// 解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { isApiResultsPayload, isApiResultsRunPayload, isDashboardFromWebviewMessage } from "../src/dashboardModel";

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
        host: "M2Ultra",
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
        host: "M2Ultra",
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
      host: "M2Ultra",
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

test("isApiResultsPayload: runs[].performanceMode が true/false/null/省略のいずれでも true と判定する", () => {
  for (const performanceMode of [true, false, null, undefined]) {
    const payload = validPayload();
    if (performanceMode === undefined) {
      delete payload.runs[0].performanceMode;
    } else {
      payload.runs[0].performanceMode = performanceMode;
    }
    assert.equal(isApiResultsPayload(payload), true, `performanceMode=${String(performanceMode)}`);
  }
});

test("isApiResultsPayload: runs[].performanceMode が文字列なら false", () => {
  const payload = validPayload();
  payload.runs[0].performanceMode = "true";
  assert.equal(isApiResultsPayload(payload), false);
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

test("isApiResultsPayload: matrix を含む完全な値も true と判定する", () => {
  const payload = validPayload({
    matrix: {
      runs: [
        { runID: "20260716-000000", startedAt: "2026-07-16T00:00:00Z", profile: "default" },
        { runID: "20260715-000000", startedAt: "2026-07-15T00:00:00Z" },
      ],
      scenarios: [
        { scenarioID: "Login", title: "Login flow", cells: [1, 0] },
        { scenarioID: "Checkout", cells: [null, 1] },
      ],
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: matrix が欠落(--matrix-runs 0 相当)でも true と判定する", () => {
  const payload = validPayload();
  assert.equal(isApiResultsPayload(payload), true);
  assert.equal("matrix" in payload, false);
});

test("isApiResultsPayload: matrix.scenarios[].cells に数値/null以外が混じれば false", () => {
  const payload = validPayload({
    matrix: {
      runs: [{ runID: "R1", startedAt: "2026-07-16T00:00:00Z" }],
      scenarios: [{ scenarioID: "Login", cells: ["true"] }],
    },
  });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: matrix.runs[] の必須フィールド欠落は false", () => {
  const payload = validPayload({
    matrix: {
      runs: [{ startedAt: "2026-07-16T00:00:00Z" }],
      scenarios: [],
    },
  });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: matrix が object でなければ false", () => {
  const payload = validPayload({ matrix: "not-an-object" });
  assert.equal(isApiResultsPayload(payload), false);
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
  delete payload.runs[0].host;
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

test("isDashboardFromWebviewMessage: runDetail/trend/openReport を runID/scenarioID/path が string のときのみ true と判定する", () => {
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: "20260716-000000" }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "trend", scenarioID: "Login" }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "openReport", path: "SampleApp/results/reports/x.md" }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: 42 }), false);
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail" }), false);
  assert.equal(isDashboardFromWebviewMessage({ type: "trend", scenarioID: null }), false);
  assert.equal(isDashboardFromWebviewMessage({ type: "openReport", path: undefined }), false);
});

test("isDashboardFromWebviewMessage: runDetail の runIDs(構成 run 全部)は省略可・string 配列のみ許容する", () => {
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: "R1", runIDs: ["R1", "R2"] }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: "R1", runIDs: [] }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: "R1", runIDs: [42] }), false);
  assert.equal(isDashboardFromWebviewMessage({ type: "runDetail", runID: "R1", runIDs: "R2" }), false);
});

test("isDashboardFromWebviewMessage: selectProject を project が string のときのみ true と判定する", () => {
  assert.equal(isDashboardFromWebviewMessage({ type: "selectProject", project: "E2E-iOS" }), true);
  assert.equal(isDashboardFromWebviewMessage({ type: "selectProject", project: 42 }), false);
  assert.equal(isDashboardFromWebviewMessage({ type: "selectProject" }), false);
});

// ---- triage(ApiResultsPayload の追加キー) --------

test("isApiResultsPayload: triage を含む完全な値も true と判定する", () => {
  const payload = validPayload({
    triage: {
      totalFailed: 12,
      unreachedCount: 3,
      rows: [
        {
          section: "action",
          command: "tap",
          failureKind: "elementNotFound",
          count: 5,
          scenarioCount: 4,
          scenarioIDs: ["Login", "Checkout"],
        },
        // section 欠落(言えないとき欄ごと省く)。
        { command: "exist", failureKind: "assertionFailed", count: 2, scenarioCount: 2, scenarioIDs: ["Login"] },
      ],
      noteCounts: [{ note: "interruption-dismissed", count: 4 }],
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: triage が欠落(旧 CLI 相当)でも true と判定する", () => {
  const payload = validPayload();
  assert.equal(isApiResultsPayload(payload), true);
  assert.equal("triage" in payload, false);
});

test("isApiResultsPayload: triage.rows は section/command/failureKind 全欠落でも true(欄の後発追加より前の記録は3欄とも無い。必須にすると実データでペイロード全体が弾かれる)", () => {
  const payload = validPayload({
    triage: {
      totalFailed: 1,
      unreachedCount: 0,
      rows: [{ count: 1, scenarioCount: 1, scenarioIDs: [] }],
      noteCounts: [],
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: triage.rows の count が数値でなければ false", () => {
  const payload = validPayload({
    triage: {
      totalFailed: 1,
      unreachedCount: 0,
      rows: [{ count: "1", scenarioCount: 1, scenarioIDs: [] }],
      noteCounts: [],
    },
  });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: machines(host→machine 読み替え表)を含む値・欠落(旧 CLI)の両方を true と判定する", () => {
  const withMachines = validPayload({
    machines: [
      { host: "LDIPC96", machine: "local" },
      { host: "SNB-M1", machine: "M1Max" },
    ],
  });
  assert.equal(isApiResultsPayload(withMachines), true);
  assert.equal(isApiResultsPayload(validPayload()), true);
});

test("isApiResultsPayload: machines の要素に host/machine が欠けていれば false", () => {
  assert.equal(isApiResultsPayload(validPayload({ machines: [{ host: "LDIPC96" }] })), false);
  assert.equal(isApiResultsPayload(validPayload({ machines: "not-an-array" })), false);
});

// ---- performance(ApiResultsPayload の追加キー) ----------------------------------------------

function validPerfRunRow(overrides = {}) {
  return {
    runID: "20260901-000000",
    startedAt: "2026-09-01T00:00:00Z",
    profile: "default",
    host: "M2Ultra",
    wallClockMs: 62000,
    scenarioTotalMs: 480000,
    scenarioCount: 12,
    passed: 11,
    failed: 1,
    maxScenarioMs: 9800,
    maxScenarioID: "Checkout",
    laneCount: 8,
    avgLaneUtilisationPct: 83.5,
    ...overrides,
  };
}

test("isApiResultsPayload: performance を含む完全な値も true と判定する", () => {
  const payload = validPayload({
    performance: {
      runs: [validPerfRunRow()],
      invalidCount: 1,
      comparison: [
        { scenarioID: "Checkout", platform: "ios", latestMs: 9800, previousMs: 9200, deltaPct: 6.5 },
      ],
      comparedRunID: "20260831-000000",
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: performance が欠落(旧 CLI 相当)でも true と判定する", () => {
  const payload = validPayload();
  assert.equal(isApiResultsPayload(payload), true);
  assert.equal("performance" in payload, false);
});

test("isApiResultsPayload: performance.runs が空配列・comparison が空配列でも true と判定する", () => {
  const payload = validPayload({
    performance: { runs: [], invalidCount: 0, comparison: [] },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: performance.runs[] の optional 欄(profile/wallClockMs/passed/failed/maxScenarioMs/maxScenarioID/avgLaneUtilisationPct)が全部キー省略でも true(triage の実害の同型回帰)", () => {
  const payload = validPayload({
    performance: {
      runs: [
        {
          runID: "20260901-000000",
          startedAt: "2026-09-01T00:00:00Z",
          host: "M2Ultra",
          scenarioTotalMs: 480000,
          scenarioCount: 12,
          laneCount: 8,
          // profile/wallClockMs/passed/failed/maxScenarioMs/maxScenarioID/avgLaneUtilisationPct 省略
        },
      ],
      invalidCount: 0,
      comparison: [],
      // comparedRunID も省略
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: performance.runs[] の optional 欄が null 明示でも true", () => {
  const payload = validPayload({
    performance: {
      runs: [
        validPerfRunRow({
          profile: null,
          wallClockMs: null,
          passed: null,
          failed: null,
          maxScenarioMs: null,
          maxScenarioID: null,
          avgLaneUtilisationPct: null,
        }),
      ],
      invalidCount: 0,
      comparison: [],
      comparedRunID: null,
    },
  });
  assert.equal(isApiResultsPayload(payload), true);
});

test("isApiResultsPayload: performance.runs が配列でなければ false", () => {
  const payload = validPayload({ performance: { runs: "not-an-array", invalidCount: 0, comparison: [] } });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: performance.runs[].laneCount(必須)が欠落していれば false", () => {
  const row = validPerfRunRow();
  delete row.laneCount;
  const payload = validPayload({ performance: { runs: [row], invalidCount: 0, comparison: [] } });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: performance.runs[].scenarioTotalMs(必須)が数値でなければ false", () => {
  const row = validPerfRunRow({ scenarioTotalMs: "480000" });
  const payload = validPayload({ performance: { runs: [row], invalidCount: 0, comparison: [] } });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: performance.comparison[].deltaPct が数値でなければ false", () => {
  const payload = validPayload({
    performance: {
      runs: [],
      invalidCount: 0,
      comparison: [{ scenarioID: "Checkout", platform: "ios", latestMs: 9800, previousMs: 9200, deltaPct: "6.5" }],
    },
  });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: performance.invalidCount が数値でなければ false", () => {
  const payload = validPayload({ performance: { runs: [], invalidCount: "1", comparison: [] } });
  assert.equal(isApiResultsPayload(payload), false);
});

test("isApiResultsPayload: performance が object でなければ false", () => {
  const payload = validPayload({ performance: "not-an-object" });
  assert.equal(isApiResultsPayload(payload), false);
});

// ---- isApiResultsRunPayload(`fleetest api results-run` の stdout) --------------------------

function validRunPayload(overrides = {}) {
  return {
    schemaVersion: 1,
    project: "SampleApp",
    run: {
      schemaVersion: 1,
      runID: "20260716-000000",
      project: "SampleApp",
      profile: "default",
      host: "M2Ultra",
      trigger: "cli",
      startedAt: "2026-07-16T00:00:00Z",
      finishedAt: "2026-07-16T00:05:00Z",
      total: 10,
      passed: 9,
      failed: 1,
    },
    scenarios: [
      {
        runID: "20260716-000000",
        scenarioID: "Checkout",
        title: "Checkout flow",
        platform: "ios",
        worker: "ios:iPhone 15",
        host: "M2Ultra",
        profile: "default",
        passed: false,
        startedAt: "2026-07-16T00:00:00Z",
        durationMs: 4200,
        scenes: [{ scene: 1, title: "ログイン画面", passed: true, durationMs: 900 }],
        steps: { total: 5, passed: 3, failed: 1, skipped: 1, healed: 0, passedViaFallback: 0 },
        reportPath: "SampleApp/results/reports/x.md",
        failedSteps: [
          {
            index: 3,
            scene: 1,
            sceneTitle: "ログイン画面",
            section: "action",
            description: "tap(#login_button)",
            command: "tap",
            failureKind: "elementNotFound",
            notes: ["interruption-dismissed"],
            detail: "element not found",
            file: "Login.swift",
            line: 42,
            durationMs: 1200,
            at: "2026-07-16T00:00:03Z",
          },
        ],
        errorLogs: ["❌ element not found"],
        skipKind: null,
        fixSuggestions: [{ scene: 1, file: "Login.swift", line: 42, oldSelector: "#old", newSelector: "#new" }],
        timeline: [],
      },
    ],
    ...overrides,
  };
}

test("isApiResultsRunPayload: 契約通りの完全な値(failedSteps 付き失敗レコード含む)を true と判定する", () => {
  assert.equal(isApiResultsRunPayload(validRunPayload()), true);
});

test("isApiResultsRunPayload: 未到達失敗(failedSteps 無し・errorLogs/skipKind のみ)も true と判定する", () => {
  const payload = validRunPayload();
  payload.scenarios = [
    {
      runID: "20260716-000000",
      scenarioID: "Checkout",
      platform: "ios",
      host: "M2Ultra",
      passed: false,
      startedAt: "2026-07-16T00:00:00Z",
      durationMs: 100,
      scenes: [],
      steps: { total: 0, passed: 0, failed: 0, skipped: 0, healed: 0, passedViaFallback: 0 },
      errorLogs: ["❌ bridge unreachable"],
      skipKind: "noWorker",
    },
  ];
  assert.equal(isApiResultsRunPayload(payload), true);
});

test("isApiResultsRunPayload: failedSteps[].description 欠落は false", () => {
  const payload = validRunPayload();
  delete payload.scenarios[0].failedSteps[0].description;
  assert.equal(isApiResultsRunPayload(payload), false);
});

test("isApiResultsRunPayload: failedSteps[].index 欠落は false", () => {
  const payload = validRunPayload();
  delete payload.scenarios[0].failedSteps[0].index;
  assert.equal(isApiResultsRunPayload(payload), false);
});

test("isApiResultsRunPayload: run が RunMetaRecord の必須フィールドを満たさなければ false", () => {
  const payload = validRunPayload();
  delete payload.run.host;
  assert.equal(isApiResultsRunPayload(payload), false);
});

test("isApiResultsRunPayload: scenarios が配列でなければ false", () => {
  const payload = validRunPayload({ scenarios: "not-an-array" });
  assert.equal(isApiResultsRunPayload(payload), false);
});

test("isApiResultsRunPayload: schemaVersion/project 欠落は false", () => {
  const payload = validRunPayload();
  delete payload.schemaVersion;
  assert.equal(isApiResultsRunPayload(payload), false);
});

test("isApiResultsRunPayload: 値が object でなければ false", () => {
  assert.equal(isApiResultsRunPayload(null), false);
  assert.equal(isApiResultsRunPayload("not json"), false);
});
