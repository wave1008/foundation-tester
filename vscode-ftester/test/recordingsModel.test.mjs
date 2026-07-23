// recordingsModel.test.mjs
// recordingsModel.ts(offsetMsForWallClock/extractScenarioFailureSource/buildRecordingErrorEntries/
// isRecordingIndex/extractScenarioTreeSource/buildRecordingTree)のユニットテスト。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildRecordingErrorEntries,
  buildRecordingTree,
  groupTreeByClass,
  extractScenarioFailureSource,
  extractScenarioTreeSource,
  isRecordingIndex,
  offsetMsForWallClock,
} from "../src/recordingsModel";

test("offsetMsForWallClock: 単一セグメント内の時刻はセグメント先頭からの差分", () => {
  const segments = [{ startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 }];
  const offset = offsetMsForWallClock(segments, "2026-07-23T00:00:10.000Z");
  assert.equal(offset, 10000);
});

test("offsetMsForWallClock: 複数セグメントの2番目に入る時刻は先行セグメント長+差分", () => {
  const segments = [
    { startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 }, // 0:00〜1:00
    { startedAt: "2026-07-23T00:01:05.000Z", durationMs: 60000 }, // 欠落5秒後、1:05〜2:05
  ];
  const offset = offsetMsForWallClock(segments, "2026-07-23T00:01:15.000Z");
  assert.equal(offset, 60000 + 10000);
});

test("offsetMsForWallClock: セグメント間の欠落(録画されていない区間)に落ちる時刻は次セグメント先頭", () => {
  const segments = [
    { startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 }, // 〜0:01:00
    { startedAt: "2026-07-23T00:01:05.000Z", durationMs: 60000 }, // 0:01:05〜
  ];
  // 0:01:02 は前セグメント終了(0:01:00)後・次セグメント開始(0:01:05)前の欠落。
  const offset = offsetMsForWallClock(segments, "2026-07-23T00:01:02.000Z");
  assert.equal(offset, 60000);
});

test("offsetMsForWallClock: 全区間より前の時刻は0にclampする", () => {
  const segments = [{ startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 }];
  const offset = offsetMsForWallClock(segments, "2026-07-22T23:59:00.000Z");
  assert.equal(offset, 0);
});

test("offsetMsForWallClock: 全区間より後の時刻は総尺にclampする", () => {
  const segments = [
    { startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 },
    { startedAt: "2026-07-23T00:01:05.000Z", durationMs: 30000 },
  ];
  const offset = offsetMsForWallClock(segments, "2026-07-23T00:10:00.000Z");
  assert.equal(offset, 90000);
});

test("offsetMsForWallClock: segments が空なら0", () => {
  assert.equal(offsetMsForWallClock([], "2026-07-23T00:00:00.000Z"), 0);
});

test("isRecordingIndex: 契約通りの値をtrueと判定する", () => {
  const value = {
    schemaVersion: 1,
    recordings: [
      {
        worker: "ios:iPhone 16",
        platform: "ios",
        file: "recordings/ios-iPhone-16.mp4",
        segments: [{ startedAt: "2026-07-23T12:34:56.789Z", durationMs: 180000 }],
      },
    ],
  };
  assert.equal(isRecordingIndex(value), true);
});

test("isRecordingIndex: platform不正・segments欠落はfalse", () => {
  assert.equal(isRecordingIndex({ schemaVersion: 1, recordings: [{ worker: "w", platform: "mac", file: "f", segments: [] }] }), false);
  assert.equal(isRecordingIndex({ schemaVersion: 1, recordings: [{ worker: "w", platform: "ios", file: "f" }] }), false);
  assert.equal(isRecordingIndex(null), false);
  assert.equal(isRecordingIndex("x"), false);
});

test("extractScenarioFailureSource: passed:trueはnull(除外対象)", () => {
  assert.equal(
    extractScenarioFailureSource({ scenarioID: "S1", startedAt: "2026-07-23T00:00:00Z", passed: true }),
    null,
  );
});

test("extractScenarioFailureSource: failedSteps/errorLogsが両方無い失敗レコードはnull", () => {
  assert.equal(
    extractScenarioFailureSource({ scenarioID: "S1", startedAt: "2026-07-23T00:00:00Z", passed: false }),
    null,
  );
});

test("extractScenarioFailureSource: 必須フィールド欠落はnull", () => {
  assert.equal(extractScenarioFailureSource({ startedAt: "2026-07-23T00:00:00Z" }), null);
  assert.equal(extractScenarioFailureSource(null), null);
});

test("extractScenarioFailureSource: failedSteps.atの有無を保持する(古い記録はatキー無し)", () => {
  const source = extractScenarioFailureSource({
    scenarioID: "S1",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T00:00:00Z",
    passed: false,
    failedSteps: [
      { description: "assertion failed", sceneTitle: "Login", detail: "expected true", at: "2026-07-23T00:00:05Z" },
      { description: "no at field" },
    ],
  });
  assert.equal(source.failedSteps.length, 2);
  assert.equal(source.failedSteps[0].at, "2026-07-23T00:00:05Z");
  assert.equal(source.failedSteps[1].at, null);
});

test("buildRecordingErrorEntries: failedStepsをステップ単位でオフセット計算する(atありは優先)", () => {
  const recordings = [
    { worker: "ios:iPhone 16", platform: "ios", file: "f.mp4", segments: [{ startedAt: "2026-07-23T00:00:00Z", durationMs: 60000 }] },
  ];
  const scenarios = [
    extractScenarioFailureSource({
      scenarioID: "S1",
      worker: "ios:iPhone 16",
      startedAt: "2026-07-23T00:00:00Z",
      passed: false,
      failedSteps: [{ description: "boom", at: "2026-07-23T00:00:10Z" }],
    }),
  ];
  const entries = buildRecordingErrorEntries(scenarios, recordings);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].offsetMs, 10000);
  assert.equal(entries[0].description, "boom");
});

test("buildRecordingErrorEntries: failedStepsが空でerrorLogsのみはシナリオ1行(位置はstartedAt)", () => {
  const recordings = [
    { worker: "android:Pixel 9", platform: "android", file: "f.mp4", segments: [{ startedAt: "2026-07-23T00:00:00Z", durationMs: 60000 }] },
  ];
  const scenarios = [
    extractScenarioFailureSource({
      scenarioID: "S2",
      worker: "android:Pixel 9",
      startedAt: "2026-07-23T00:00:20Z",
      passed: false,
      errorLogs: ["❌ bridge timeout", "⚠️ retry exhausted"],
    }),
  ];
  const entries = buildRecordingErrorEntries(scenarios, recordings);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].offsetMs, 20000);
  assert.equal(entries[0].description, "❌ bridge timeout\n⚠️ retry exhausted");
});

test("buildRecordingErrorEntries: at昇順にソートする", () => {
  const recordings = [
    { worker: "ios:iPhone 16", platform: "ios", file: "f.mp4", segments: [{ startedAt: "2026-07-23T00:00:00Z", durationMs: 120000 }] },
  ];
  const scenarios = [
    extractScenarioFailureSource({
      scenarioID: "S-late",
      worker: "ios:iPhone 16",
      startedAt: "2026-07-23T00:00:00Z",
      passed: false,
      failedSteps: [{ description: "later", at: "2026-07-23T00:01:00Z" }],
    }),
    extractScenarioFailureSource({
      scenarioID: "S-early",
      worker: "ios:iPhone 16",
      startedAt: "2026-07-23T00:00:00Z",
      passed: false,
      failedSteps: [{ description: "earlier", at: "2026-07-23T00:00:10Z" }],
    }),
  ];
  const entries = buildRecordingErrorEntries(scenarios, recordings);
  assert.deepEqual(entries.map((e) => e.scenarioID), ["S-early", "S-late"]);
});

test("buildRecordingErrorEntries: worker に対応する録画が無ければoffsetMsは0", () => {
  const scenarios = [
    extractScenarioFailureSource({
      scenarioID: "S3",
      worker: "ios:Unknown Device",
      startedAt: "2026-07-23T00:00:20Z",
      passed: false,
      errorLogs: ["❌ no recording"],
    }),
  ];
  const entries = buildRecordingErrorEntries(scenarios, []);
  assert.equal(entries[0].offsetMs, 0);
});

// ---- extractScenarioTreeSource ----

test("extractScenarioTreeSource: 正常な値を読み取る(timeline/scenes込み)", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "Login",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:30Z",
    passed: true,
    scenes: [{ scene: 1, title: "ログインできる", passed: true, durationMs: 4000 }],
    timeline: [
      {
        scene: 1,
        sceneTitle: "ログインできる",
        index: 3,
        description: 'tap "#btn"',
        status: "passed",
        at: "2026-07-23T15:55:34.642Z",
        durationMs: 1300,
      },
    ],
  });
  assert.equal(source.scenarioID, "Login");
  assert.equal(source.worker, "ios:iPhone 16");
  assert.equal(source.passed, true);
  assert.equal(source.scenePassed.get(1), true);
  assert.equal(source.timeline.length, 1);
  assert.equal(source.timeline[0].description, 'tap "#btn"');
});

test("extractScenarioTreeSource: scenarioID/startedAt が読めなければnull", () => {
  assert.equal(extractScenarioTreeSource({ startedAt: "2026-07-23T00:00:00Z" }), null);
  assert.equal(extractScenarioTreeSource({ scenarioID: "S1" }), null);
  assert.equal(extractScenarioTreeSource(null), null);
});

test("extractScenarioTreeSource: timeline/scenes 欠落は空(古い記録との互換)。passed 欠落は false 扱い", () => {
  const source = extractScenarioTreeSource({ scenarioID: "S1", startedAt: "2026-07-23T00:00:00Z" });
  assert.deepEqual(source.timeline, []);
  assert.equal(source.scenePassed.size, 0);
  assert.equal(source.passed, false);
});

test("extractScenarioTreeSource: timeline 要素は index/description/status が揃わないものをスキップする", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "S1",
    startedAt: "2026-07-23T00:00:00Z",
    timeline: [
      { index: 0, description: "ok", status: "passed" },
      { index: 1, description: "no status" },
      "not-an-object",
      { index: 2, status: "passed" }, // description 無し
    ],
  });
  assert.equal(source.timeline.length, 1);
  assert.equal(source.timeline[0].index, 0);
});

// ---- buildRecordingTree ----

const RECORDINGS_1H = [
  { worker: "ios:iPhone 16", platform: "ios", file: "f.mp4", segments: [{ startedAt: "2026-07-23T15:55:00Z", durationMs: 3600000 }] },
];

test("buildRecordingTree: timeline が無い記録はシナリオノードのみ(scenes:[])", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "OldScenario",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:10Z",
    passed: true,
  });
  const tree = buildRecordingTree([source], RECORDINGS_1H);
  assert.equal(tree.length, 1);
  assert.deepEqual(tree[0].scenes, []);
  assert.equal(tree[0].status, "passed");
  assert.equal(tree[0].offsetMs, 10000); // startedAt - 15:55:00 = 10s
});

test("buildRecordingTree: timeline ありはシーン→ステップの階層を構築する", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "Login",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:00Z",
    passed: true,
    timeline: [
      { scene: 1, sceneTitle: "ログインできる", index: 0, description: "tap #email", status: "passed", at: "2026-07-23T15:55:01Z" },
      { scene: 1, sceneTitle: "ログインできる", index: 1, description: "tap #btn", status: "passed", at: "2026-07-23T15:55:02Z" },
      { scene: 2, sceneTitle: "ホームに戻る", index: 2, description: "tap #back", status: "passed", at: "2026-07-23T15:55:05Z" },
    ],
  });
  const tree = buildRecordingTree([source], RECORDINGS_1H);
  assert.equal(tree[0].scenes.length, 2);
  assert.equal(tree[0].scenes[0].scene, 1);
  assert.equal(tree[0].scenes[0].sceneTitle, "ログインできる");
  assert.equal(tree[0].scenes[0].steps.length, 2);
  assert.equal(tree[0].scenes[0].steps[1].description, "tap #btn");
  assert.equal(tree[0].scenes[1].scene, 2);
  assert.equal(tree[0].scenes[1].steps.length, 1);
});

test("buildRecordingTree: ステップ開始壁時計は at-durationMs、無ければ at、無ければシーン最初のat、無ければシナリオstartedAt", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "S1",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:00Z",
    passed: true,
    timeline: [
      // at - durationMs: 15:55:01 - 1000ms = 15:55:00 → offset 0s
      { scene: 1, index: 0, description: "a", status: "passed", at: "2026-07-23T15:55:01Z", durationMs: 1000 },
      // durationMs 無し: at をそのまま使う → offset 3s
      { scene: 1, index: 1, description: "b", status: "passed", at: "2026-07-23T15:55:03Z" },
      // at 無し: シーン内で at を持つ最初のステップ(index0のat=15:55:01)にフォールバック → offset 1s
      { scene: 1, index: 2, description: "c", status: "passed" },
      // シーン2は at を持つステップが無い → シナリオ startedAt(15:55:00)にフォールバック → offset 0s
      { scene: 2, index: 3, description: "d", status: "passed" },
    ],
  });
  const tree = buildRecordingTree([source], RECORDINGS_1H);
  const [scene1, scene2] = tree[0].scenes;
  assert.equal(scene1.steps[0].offsetMs, 0);
  assert.equal(scene1.steps[1].offsetMs, 3000);
  assert.equal(scene1.steps[2].offsetMs, 1000);
  assert.equal(scene2.steps[0].offsetMs, 0);
});

test("buildRecordingTree: シーンの合否は配下のfailedで決まり、シナリオはシーンのfailedで決まる", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "S1",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:00Z",
    passed: false,
    timeline: [
      { scene: 1, index: 0, description: "a", status: "passed", at: "2026-07-23T15:55:01Z" },
      { scene: 2, index: 1, description: "b", status: "failed", at: "2026-07-23T15:55:02Z" },
      { scene: 2, index: 2, description: "c", status: "skipped", at: "2026-07-23T15:55:03Z" },
    ],
  });
  const tree = buildRecordingTree([source], RECORDINGS_1H);
  const [scene1, scene2] = tree[0].scenes;
  assert.equal(scene1.status, "passed");
  assert.equal(scene1.steps[0].status, "passed");
  assert.equal(scene2.status, "failed");
  assert.equal(scene2.steps[0].status, "failed");
  assert.equal(scene2.steps[1].status, "other"); // "skipped" は passed/failed どちらでもない
  assert.equal(tree[0].status, "failed"); // 配下(scene2)が failed
});

test("buildRecordingTree: 配下に failed が無ければ scenes[].passed を優先してシーンの合否を決める", () => {
  const source = extractScenarioTreeSource({
    scenarioID: "S1",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:00Z",
    passed: false,
    scenes: [{ scene: 1, title: "t", passed: false }],
    timeline: [{ scene: 1, index: 0, description: "a", status: "passed", at: "2026-07-23T15:55:01Z" }],
  });
  const tree = buildRecordingTree([source], RECORDINGS_1H);
  assert.equal(tree[0].scenes[0].status, "failed"); // ステップは passed だが scenes[].passed:false を優先
});

test("buildRecordingTree: startedAt 昇順に並べ替える", () => {
  const late = extractScenarioTreeSource({
    scenarioID: "Late",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:56:00Z",
    passed: true,
  });
  const early = extractScenarioTreeSource({
    scenarioID: "Early",
    worker: "ios:iPhone 16",
    startedAt: "2026-07-23T15:55:00Z",
    passed: true,
  });
  const tree = buildRecordingTree([late, early], RECORDINGS_1H);
  assert.deepEqual(tree.map((s) => s.scenarioID), ["Early", "Late"]);
});

test("buildRecordingErrorEntries: scene/stepIndex がフィルター照合用に載る(errorLogs 行は null)", () => {
  const recordings = [
    { worker: "ios:A", platform: "ios", file: "recordings/a.mp4",
      segments: [{ startedAt: "2026-07-23T00:00:00.000Z", durationMs: 60000 }] },
  ];
  const scenarios = [
    { scenarioID: "S1", worker: "ios:A", startedAt: "2026-07-23T00:00:01.000Z",
      failedSteps: [{ scene: 2, index: 5, sceneTitle: "シーン名", description: "tap", detail: null,
                      at: "2026-07-23T00:00:10.000Z" }],
      errorLogs: [] },
    { scenarioID: "S2", worker: "ios:A", startedAt: "2026-07-23T00:00:20.000Z",
      failedSteps: [], errorLogs: ["❌ boom"] },
  ];
  const entries = buildRecordingErrorEntries(scenarios, recordings);
  assert.equal(entries.length, 2);
  assert.equal(entries[0].scene, 2);
  assert.equal(entries[0].stepIndex, 5);
  assert.equal(entries[1].scene, null);
  assert.equal(entries[1].stepIndex, null);
});

test("extractScenarioFailureSource: failedSteps の scene/index を抽出(欠落は null)", () => {
  const source = extractScenarioFailureSource({
    scenarioID: "S", startedAt: "2026-07-23T00:00:00.000Z", worker: "ios:A", passed: false,
    failedSteps: [
      { scene: 3, index: 7, description: "tap" },
      { description: "no-position" },
    ],
  });
  assert.equal(source.failedSteps[0].scene, 3);
  assert.equal(source.failedSteps[0].index, 7);
  assert.equal(source.failedSteps[1].scene, null);
  assert.equal(source.failedSteps[1].index, null);
});

test("groupTreeByClass: クラス名(最後のドットまで)でグルーピングし、初出順・failed 伝搬を保つ", () => {
  const scenario = (id, status) => ({ scenarioID: id, worker: "ios:A", status, offsetMs: 0, scenes: [] });
  const grouped = groupTreeByClass([
    scenario("クラスA.S0010", "passed"),
    scenario("クラスB.S0010", "passed"),
    scenario("クラスA.S0020", "failed"),
    scenario("ドット無しID", "passed"),
  ]);
  assert.deepEqual(grouped.map((c) => c.classID), ["クラスA", "クラスB", "ドット無しID"]);
  assert.deepEqual(grouped[0].scenarios.map((s) => s.method), ["S0010", "S0020"]);
  assert.equal(grouped[0].status, "failed"); // 配下に failed があれば failed
  assert.equal(grouped[1].status, "passed");
  assert.equal(grouped[2].scenarios[0].method, "ドット無しID");
});
