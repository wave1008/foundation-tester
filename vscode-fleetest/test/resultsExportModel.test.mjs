// resultsExportModel.test.mjs
// resultsExportModel.ts(extractResultsExportScenarioSource/buildResultsExportModel)のユニットテスト。
// 「テストセッション」タブの「テスト結果をエクスポート」が読む scenarios/*.json・run.json 抜粋 →
// 中立モデルの変換(locale には触れない。文言解決は resultsExportWorkbook.ts の責務)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { buildResultsExportModel, extractResultsExportScenarioSource } from "../src/resultsExportModel";

function timelineStep(overrides = {}) {
  return {
    scene: null,
    sceneTitle: null,
    section: null,
    index: 0,
    description: "step",
    status: "passed",
    ...overrides,
  };
}

function extract(raw, overrides = {}) {
  const { fallbackProfile = null, machine = null, videoPath = null } = overrides;
  return extractResultsExportScenarioSource(raw, fallbackProfile, machine, videoPath);
}

function modelFrom(sources, runMetas = []) {
  return buildResultsExportModel("SampleApp", sources, runMetas);
}

// ---- extractResultsExportScenarioSource ----

test("extractResultsExportScenarioSource: scenarioID が無ければ null", () => {
  assert.equal(extract({}), null);
  assert.equal(extract(null), null);
});

test("extractResultsExportScenarioSource: クラス名/メソッド名は最後のドットで分割(ドット無しは全体を両方に使う)", () => {
  const a = extract({ scenarioID: "デモ.ログイン.S0010" });
  assert.equal(a.className, "デモ.ログイン");
  assert.equal(a.methodName, "S0010");

  const b = extract({ scenarioID: "S0010" });
  assert.equal(b.className, "S0010");
  assert.equal(b.methodName, "S0010");
});

test("extractResultsExportScenarioSource: profile はレコード自身の値を優先し、欠落時だけ run 側フォールバックを使う", () => {
  const withOwn = extract({ scenarioID: "C.M", profile: "own-profile" }, { fallbackProfile: "fallback-profile" });
  assert.equal(withOwn.profile, "own-profile");

  const withoutOwn = extract({ scenarioID: "C.M" }, { fallbackProfile: "fallback-profile" });
  assert.equal(withoutOwn.profile, "fallback-profile");
});

test("extractResultsExportScenarioSource: machine(run.json 由来)・videoPath は呼び出し側の引数をそのまま持つ", () => {
  const source = extract({ scenarioID: "C.M" }, { machine: "mac-mini-1", videoPath: "/runs/x/rec.mp4" });
  assert.equal(source.machine, "mac-mini-1");
  assert.equal(source.videoPath, "/runs/x/rec.mp4");
});

test("extractResultsExportScenarioSource: 自己修復数は steps.healed + steps.passedViaFallback(欠落は0)", () => {
  const withCounts = extract({ scenarioID: "C.M", steps: { healed: 2, passedViaFallback: 1 } });
  assert.equal(withCounts.healedCount, 3);
  const withoutSteps = extract({ scenarioID: "C.M" });
  assert.equal(withoutSteps.healedCount, 0);
});

test("extractResultsExportScenarioSource: timeline/failedSteps/errorLogs は寛容に読む(壊れた要素は無視)", () => {
  const source = extract({
    scenarioID: "C.M",
    passed: false,
    timedOut: true,
    interrupted: true,
    skipKind: "noWorker",
    startedAt: "2026-09-20T00:00:00.000Z",
    durationMs: 1500,
    errorLogs: ["boom", 1, null],
    timeline: [
      timelineStep({ index: 0, description: "ok", notes: ["n1", 2] }),
      { index: 1 },
      "not-an-object",
    ],
    failedSteps: [
      { index: 0, description: "f", command: "tap", failureKind: "not-found", file: "a.swift", line: 12, notes: ["x"] },
      {},
    ],
  });
  assert.equal(source.passed, false);
  assert.equal(source.timedOut, true);
  assert.equal(source.interrupted, true);
  assert.equal(source.skipKind, "noWorker");
  assert.equal(source.durationMs, 1500);
  assert.deepEqual(source.errorLogs, ["boom"]);
  assert.equal(source.timeline.length, 1, "description/status を欠く要素は捨てる");
  assert.deepEqual(source.timeline[0].notes, ["n1"], "notes の非文字列は捨てる");
  assert.equal(source.failedSteps.length, 1, "description を欠く要素は捨てる");
  assert.equal(source.failedSteps[0].failureKind, "not-found");
  assert.equal(source.failedSteps[0].file, "a.swift");
  assert.equal(source.failedSteps[0].line, 12);
});

// ---- buildResultsExportModel: シナリオ結果の判定 ----

test("結果判定: skipKind があれば passed の値に関わらずスキップ", () => {
  const source = extract({ scenarioID: "C.S1", passed: true, skipKind: "notApplicable", startedAt: "2026-09-20T00:00:00.000Z" });
  const row = modelFrom([source]).scenarios[0];
  assert.equal(row.result, "skipped");
});

test("結果判定: timedOut ならタイムアウト", () => {
  const source = extract({ scenarioID: "C.S1", passed: false, timedOut: true, startedAt: "2026-09-20T00:00:00.000Z" });
  assert.equal(modelFrom([source]).scenarios[0].result, "timeout");
});

test("結果判定: interrupted(timedOut ではない)なら中断", () => {
  const source = extract({ scenarioID: "C.S1", passed: false, interrupted: true, startedAt: "2026-09-20T00:00:00.000Z" });
  assert.equal(modelFrom([source]).scenarios[0].result, "interrupted");
});

test("結果判定: passed:true(他フラグ無し)なら成功", () => {
  const source = extract({ scenarioID: "C.S1", passed: true, startedAt: "2026-09-20T00:00:00.000Z" });
  assert.equal(modelFrom([source]).scenarios[0].result, "success");
});

test("結果判定: passed:false(他フラグ無し)なら失敗", () => {
  const source = extract({ scenarioID: "C.S1", passed: false, startedAt: "2026-09-20T00:00:00.000Z" });
  assert.equal(modelFrom([source]).scenarios[0].result, "failure");
});

// ---- buildResultsExportModel: 失敗シナリオ行の各欄 ----

test("失敗行: failedSteps[0] から失敗した scene/ステップ/経路/理由/注記/ソースを埋める", () => {
  const source = extract({
    scenarioID: "C.S1",
    passed: false,
    startedAt: "2026-09-20T00:00:00.000Z",
    scenes: [{ scene: 1, title: "ログイン画面" }],
    timeline: [timelineStep({ scene: 1, sceneTitle: "ログイン画面", section: "expectation", index: 0, description: "assert" })],
    failedSteps: [
      {
        index: 0, scene: 1, sceneTitle: "ログイン画面", description: "assert", command: "exist",
        failureKind: "not-found", detail: "#btn not found", notes: ["retry-exhausted"], file: "TestProjects/x/S1.swift", line: 42,
      },
    ],
  });
  const row = modelFrom([source]).scenarios[0];
  assert.equal(row.failedScene, 1);
  assert.equal(row.failedSceneTitle, "ログイン画面");
  assert.equal(row.failedStepDescription, "assert");
  assert.equal(row.failureKind, "not-found");
  assert.equal(row.reason, "#btn not found");
  assert.deepEqual(row.failedStepNotes, ["retry-exhausted"]);
  assert.equal(row.sourceFile, "TestProjects/x/S1.swift");
  assert.equal(row.sourceLine, 42);
});

test("シナリオ単位の失敗(failedStep 無し)は timedOut/interrupted/skipKind + errorLogs を理由にする", () => {
  const source = extract({
    scenarioID: "C.S1", passed: false, timedOut: true, startedAt: "2026-09-20T00:00:00.000Z",
    errorLogs: ["⏱ timeout waiting for element"],
  });
  const row = modelFrom([source]).scenarios[0];
  assert.equal(row.result, "timeout");
  assert.equal(row.failedStepDescription, null);
  assert.ok(row.reason.includes("timedOut"));
  assert.ok(row.reason.includes("⏱ timeout waiting for element"));
});

test("成功シナリオは理由・失敗欄がすべて null/空", () => {
  const source = extract({ scenarioID: "C.S1", passed: true, startedAt: "2026-09-20T00:00:00.000Z" });
  const row = modelFrom([source]).scenarios[0];
  assert.equal(row.reason, null);
  assert.equal(row.failedScene, null);
  assert.equal(row.failedStepDescription, null);
  assert.equal(row.failureKind, null);
  assert.deepEqual(row.failedStepNotes, []);
  assert.equal(row.sourceFile, null);
});

// ---- 重複シナリオ・並び順 ----

test("重複シナリオ規則: 同一 scenarioID の再実行(~2 連番)は de-dup せず startedAt 昇順で別行として並ぶ", () => {
  const first = extract({ scenarioID: "C.S1", passed: false, startedAt: "2026-09-20T00:00:00.000Z" });
  const retry = extract({ scenarioID: "C.S1", passed: true, startedAt: "2026-09-20T00:05:00.000Z" });
  const model = modelFrom([retry, first]);
  assert.equal(model.scenarios.length, 2);
  assert.equal(model.scenarios[0].result, "failure", "startedAt が早いほうが先");
  assert.equal(model.scenarios[1].result, "success");
});

test("並び: startedAt が読めないシナリオは末尾に置く", () => {
  const withDate = extract({ scenarioID: "C.S1", passed: true, startedAt: "2026-09-20T00:00:00.000Z" });
  const noDate = extract({ scenarioID: "C.S2", passed: true });
  const model = modelFrom([noDate, withDate]);
  assert.deepEqual(model.scenarios.map((s) => s.scenarioID), ["C.S1", "C.S2"]);
});

// ---- クラス集計 ----

test("クラス集計: 初出順・シナリオ数・成功数・失敗数(スキップは別勘定)・所要合計", () => {
  const a = extract({ scenarioID: "B.S1", passed: true, startedAt: "2026-09-20T00:00:01.000Z", durationMs: 1000 });
  const b = extract({ scenarioID: "A.S1", passed: true, startedAt: "2026-09-20T00:00:00.000Z", durationMs: 2000 });
  const c = extract({ scenarioID: "A.S2", passed: false, startedAt: "2026-09-20T00:00:02.000Z", durationMs: 500 });
  const d = extract({ scenarioID: "A.S3", passed: false, skipKind: "filtered", startedAt: "2026-09-20T00:00:03.000Z", durationMs: 100 });
  const model = modelFrom([a, b, c, d]);
  assert.deepEqual(model.classes.map((cl) => cl.classID), ["A", "B"], "startedAt 昇順で見た初出順");
  const classA = model.classes.find((cl) => cl.classID === "A");
  assert.equal(classA.scenarioCount, 3);
  assert.equal(classA.passedCount, 1);
  assert.equal(classA.failedCount, 1, "スキップは failedCount に混ぜない");
  assert.equal(classA.skippedCount, 1);
  assert.equal(classA.durationMsSum, 2600);
});

// ---- 概要(overview) ----

function runMeta(overrides = {}) {
  return {
    runID: "20260920-000000",
    startedAt: null,
    finishedAt: null,
    trigger: null,
    issuer: null,
    profile: null,
    machine: null,
    fmSettings: null,
    ...overrides,
  };
}

test("概要: 複数 run から最も早い開始・最も遅い終了・所要秒を導く", () => {
  const metas = [
    runMeta({ runID: "r1", startedAt: "2026-09-20T00:00:00.000Z", finishedAt: "2026-09-20T00:05:00.000Z" }),
    runMeta({ runID: "r2", startedAt: "2026-09-20T00:01:00.000Z", finishedAt: "2026-09-20T00:10:00.000Z" }),
  ];
  const overview = modelFrom([], metas).overview;
  assert.deepEqual(overview.runIDs, ["r1", "r2"]);
  assert.equal(overview.startedAt, "2026-09-20T00:00:00.000Z");
  assert.equal(overview.finishedAt, "2026-09-20T00:10:00.000Z");
  assert.equal(overview.durationSeconds, 600);
});

test("概要: プロファイル/マシン/起動元/実行者は run 横断で重複排除して初出順に並ぶ", () => {
  const metas = [
    runMeta({ runID: "r1", profile: "p1", machine: "mac-1", trigger: "cli", issuer: "alice" }),
    runMeta({ runID: "r2", profile: "p1", machine: "mac-2", trigger: "api", issuer: "alice" }),
  ];
  const overview = modelFrom([], metas).overview;
  assert.deepEqual(overview.profiles, ["p1"]);
  assert.deepEqual(overview.machines, ["mac-1", "mac-2"]);
  assert.deepEqual(overview.triggers, ["cli", "api"]);
  assert.deepEqual(overview.issuers, ["alice"]);
});

test("概要: fmSettings は最初に見つかった非 null 値を代表として使う", () => {
  const fm = { heal: true, textVisualCheck: false, screenLooksLike: true, ocrTextVisualCheck: false };
  const metas = [runMeta({ runID: "r1", fmSettings: null }), runMeta({ runID: "r2", fmSettings: fm })];
  assert.deepEqual(modelFrom([], metas).overview.fmSettings, fm);
});

test("概要: シナリオ件数はシナリオの結果種別ごとの合計", () => {
  const sources = [
    extract({ scenarioID: "C.S1", passed: true, startedAt: "2026-09-20T00:00:00.000Z" }),
    extract({ scenarioID: "C.S2", passed: false, startedAt: "2026-09-20T00:00:01.000Z" }),
    extract({ scenarioID: "C.S3", passed: false, timedOut: true, startedAt: "2026-09-20T00:00:02.000Z" }),
    extract({ scenarioID: "C.S4", passed: false, interrupted: true, startedAt: "2026-09-20T00:00:03.000Z" }),
    extract({ scenarioID: "C.S5", passed: true, skipKind: "notApplicable", startedAt: "2026-09-20T00:00:04.000Z" }),
  ];
  const overview = modelFrom(sources).overview;
  assert.equal(overview.scenarioTotal, 5);
  assert.equal(overview.scenarioPassed, 1);
  assert.equal(overview.scenarioFailed, 1);
  assert.equal(overview.scenarioTimedOut, 1);
  assert.equal(overview.scenarioInterrupted, 1);
  assert.equal(overview.scenarioSkipped, 1);
});

test("概要: ステップ件数は steps.* ではなく timeline の実数を状態別に数える", () => {
  const source = extract({
    scenarioID: "C.S1",
    passed: true,
    startedAt: "2026-09-20T00:00:00.000Z",
    steps: { healed: 99 }, // シナリオ行の healedCount 専用。overview の集計には使わない
    timeline: [
      timelineStep({ index: 0, status: "passed" }),
      timelineStep({ index: 1, status: "passedViaFallback" }),
      timelineStep({ index: 2, status: "healed" }),
      timelineStep({ index: 3, status: "failed" }),
      timelineStep({ index: 4, status: "skipped" }),
    ],
  });
  const overview = modelFrom([source]).overview;
  assert.equal(overview.stepTotal, 5);
  assert.equal(overview.stepPassed, 1);
  assert.equal(overview.stepPassedViaFallback, 1);
  assert.equal(overview.stepHealed, 1);
  assert.equal(overview.stepFailed, 1);
  assert.equal(overview.stepSkipped, 1);
});
