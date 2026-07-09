// runLaneModel.test.mjs
// runLaneModel.ts(reduceLaneEvent/snapshotRunLaneState/forceEndRunLaneState)のユニットテスト。
// node:test で実行する。esbuild が "../src/runLaneModel"(拡張子なし)を runLaneModel.ts に
// 解決してバンドルする。
//
// 末尾に、mock-runner.mjs(--pattern parallel)を実際に spawn して NdjsonParser →
// reduceLaneEvent に通す統合テストを1本含む(monitorPanel.ts の配線を再現する。
// runReducer.test.mjs / monitorModel.test.mjs の mock 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  createRunLaneState,
  forceEndRunLaneState,
  MAX_LANE_LINES,
  OVERALL_LANE_ID,
  OVERALL_LANE_NAME,
  reduceLaneEvent,
  snapshotRunLaneState,
} from "../src/runLaneModel";

const MOCK_RUNNER = path.resolve(process.cwd(), "test", "fixtures", "mock-runner.mjs");

/** 複数イベントを1つのレーン状態に順に適用し、発生した LaneAction を1配列にまとめて返す。 */
function feed(state, events, { nowMs = () => 1000 } = {}) {
  const actions = [];
  let tick = 0;
  for (const event of events) {
    const now = typeof nowMs === "function" ? nowMs(tick) : nowMs;
    actions.push(...reduceLaneEvent(state, event, now));
    tick += 1;
  }
  return actions;
}

test("workersReady: lanesConfigured アクションでレーン構成が反映される", () => {
  const state = createRunLaneState();
  const workers = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "port 8127" },
    { id: "android:エミュ1", name: "エミュ1", platform: "android", detail: "port 5555" },
  ];
  const actions = feed(state, [{ kind: "workersReady", workers }]);

  const configured = actions.find((a) => a.type === "lanesConfigured");
  assert.ok(configured);
  assert.deepEqual(
    configured.lanes.map((l) => l.id),
    ["ios:シミュ1", "android:エミュ1"],
  );
  assert.equal(configured.lanes[0].name, "シミュ1");
  assert.equal(configured.lanes[0].platform, "ios");
});

test("worker フィールドが無いイベント(逐次実行)は全体レーン(OVERALL_LANE_ID)に集約される", () => {
  const state = createRunLaneState();
  const actions = feed(state, [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "sceneStarted", scenario: "S.T1", scene: 1, sceneTitle: "シーン1" },
  ]);

  const lineActions = actions.filter((a) => a.type === "line");
  assert.ok(lineActions.length > 0);
  assert.ok(lineActions.every((a) => a.laneId === OVERALL_LANE_ID));

  const snapshot = snapshotRunLaneState(state);
  assert.deepEqual(
    snapshot.lanes.map((l) => l.id),
    [OVERALL_LANE_ID],
  );
  assert.equal(snapshot.lanes[0].name, OVERALL_LANE_NAME);
});

test("worker 付きイベントはその worker id のレーンに振り分けられる", () => {
  const state = createRunLaneState();
  const actions = feed(state, [
    { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
    { kind: "scenarioStarted", scenario: "S.B", title: "B", worker: "ios:シミュ2" },
  ]);

  const lineActions = actions.filter((a) => a.type === "line");
  assert.deepEqual(
    lineActions.map((a) => a.laneId).sort(),
    ["ios:シミュ1", "ios:シミュ2"],
  );
});

test("scenarioStarted〜scenarioFinished の間、そのworkerは workerRunning:true になる", () => {
  const state = createRunLaneState();
  const actions = feed(state, [
    { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
    { kind: "scenarioFinished", scenario: "S.A", passed: true, worker: "ios:シミュ1" },
  ]);

  const runningActions = actions.filter((a) => a.type === "workerRunning");
  assert.deepEqual(
    runningActions.map((a) => [a.workerId, a.running]),
    [
      ["ios:シミュ1", true],
      ["ios:シミュ1", false],
    ],
  );
});

test("scenarioFinished(passed:true) の行には所要時間が付く", () => {
  const state = createRunLaneState();
  const actions = feed(
    state,
    [
      { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
      { kind: "scenarioFinished", scenario: "S.A", passed: true, worker: "ios:シミュ1" },
    ],
    { nowMs: (tick) => (tick === 0 ? 1000 : 1500) },
  );

  const finishLine = actions.find((a) => a.type === "line" && a.text.includes("成功"));
  assert.ok(finishLine);
  assert.match(finishLine.text, /\(500ms\)/);
});

test("runStarted: cleared アクションでレーン・実行中状態・行が全てクリアされる", () => {
  const state = createRunLaneState();
  feed(state, [
    { kind: "workersReady", workers: [{ id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "" }] },
    { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
  ]);
  assert.ok(snapshotRunLaneState(state).lanes.length > 0);

  const actions = feed(state, [{ kind: "runStarted", total: 1 }]);
  assert.deepEqual(actions, [{ type: "cleared" }]);

  const snapshot = snapshotRunLaneState(state);
  assert.deepEqual(snapshot.lanes, []);
  assert.deepEqual(snapshot.runningWorkers, []);
});

test("runFinished: 実行中のワーカーが全て workerRunning:false になり、runFinished アクションが発生する", () => {
  const state = createRunLaneState();
  feed(state, [
    { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
    // scenarioFinished を受信しないまま runFinished が来た(クラッシュ相当)想定
  ]);

  const actions = feed(state, [{ kind: "runFinished", passed: 0, failed: 1 }]);
  assert.ok(actions.some((a) => a.type === "workerRunning" && a.workerId === "ios:シミュ1" && !a.running));
  assert.ok(actions.some((a) => a.type === "runFinished" && a.passed === 0 && a.failed === 1));
});

test("forceEndRunLaneState: 実行中のワーカーを強制的に workerRunning:false にする(プロセス突然死の後始末)", () => {
  const state = createRunLaneState();
  feed(state, [{ kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" }]);

  const actions = forceEndRunLaneState(state);
  assert.deepEqual(actions, [{ type: "workerRunning", workerId: "ios:シミュ1", running: false }]);
  assert.deepEqual(snapshotRunLaneState(state).runningWorkers, []);

  // 既に running が無ければ何も起きない(冪等)
  assert.deepEqual(forceEndRunLaneState(state), []);
});

test("500行キャップ: レーンごとに最大500行で古い行から捨てられる(スナップショットで確認)", () => {
  const state = createRunLaneState();
  const events = [];
  for (let i = 0; i < MAX_LANE_LINES + 20; i += 1) {
    events.push({ kind: "log", scenario: "S.A", message: `line-${i}` });
  }
  feed(state, events);

  const snapshot = snapshotRunLaneState(state);
  const lines = snapshot.linesByLane[OVERALL_LANE_ID];
  assert.equal(lines.length, MAX_LANE_LINES);
  // 先頭20件が捨てられ、末尾が最新であること
  assert.ok(lines[0].includes("line-20"));
  assert.ok(lines[lines.length - 1].includes(`line-${MAX_LANE_LINES + 19}`));
});

test("log イベント: 空メッセージは行を追加しない", () => {
  const state = createRunLaneState();
  const actions = feed(state, [{ kind: "log", scenario: "S.A", message: "" }]);
  assert.deepEqual(actions, []);
});

test("paused イベント: レーン表示は不要なのでアクションが発生しない", () => {
  const state = createRunLaneState();
  const actions = feed(state, [
    { kind: "paused", scenario: "S.A", index: 1, description: "x", file: "a.swift", line: 1 },
  ]);
  assert.deepEqual(actions, []);
});

test("fixSuggestion: 修正提案の行(+ oldSelector→newSelector の行)が対応するレーンに追加される", () => {
  const state = createRunLaneState();
  const actions = feed(state, [
    {
      kind: "fixSuggestion",
      scenario: "S.A",
      description: 'tap "#old_id"',
      detail: "ロケータが変化した可能性があります",
      oldSelector: "#old_id",
      newSelector: "#new_id",
      worker: "ios:シミュ1",
    },
  ]);
  const lines = actions.filter((a) => a.type === "line");
  assert.equal(lines.length, 2);
  assert.ok(lines[0].text.includes("修正提案"));
  assert.ok(lines[1].text.includes("#old_id → #new_id"));
  assert.ok(lines.every((a) => a.laneId === "ios:シミュ1"));
});

test("統合: mock-runner.mjs(parallel パターン)の出力を NdjsonParser → reduceLaneEvent に通すと、レーン別の行と正しい実行中状態の遷移が得られる", async () => {
  const { actions } = await runMockThroughLanePipeline([
    "--pattern",
    "parallel",
    "--scenario",
    "並列.A",
    "--scenario",
    "並列.B",
  ]);

  const configured = actions.find((a) => a.type === "lanesConfigured");
  assert.ok(configured);
  assert.deepEqual(
    configured.lanes.map((l) => l.id),
    ["ios:シミュ1", "ios:シミュ2"],
  );

  const laneIdsWithLines = new Set(actions.filter((a) => a.type === "line").map((a) => a.laneId));
  assert.deepEqual([...laneIdsWithLines].sort(), ["ios:シミュ1", "ios:シミュ2"]);

  // 各ワーカーとも running:true → running:false の順で1回ずつ遷移する
  const runningByWorker = new Map();
  for (const a of actions.filter((a) => a.type === "workerRunning")) {
    const list = runningByWorker.get(a.workerId) ?? [];
    list.push(a.running);
    runningByWorker.set(a.workerId, list);
  }
  assert.deepEqual(runningByWorker.get("ios:シミュ1"), [true, false]);
  assert.deepEqual(runningByWorker.get("ios:シミュ2"), [true, false]);

  const finished = actions.find((a) => a.type === "runFinished");
  assert.deepEqual(finished, { type: "runFinished", passed: 1, failed: 1 });
});

/**
 * mock-runner.mjs を spawn し、stdout を NdjsonParser → reduceLaneEvent に通して発生した
 * LaneAction 全体を返す(monitorPanel.ts が組む配線の縮小版)。isRunEvent 相当の判別は
 * NdjsonParser が返す value の kind を素朴にチェックする(model.ts の isRunEvent を使ってもよいが、
 * このテストではモデルの網羅性より配線の確認を主眼にするため簡略化する)。
 */
function runMockThroughLanePipeline(mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_RUNNER, ...mockArgs], {
      cwd: path.dirname(MOCK_RUNNER),
      stdio: ["ignore", "pipe", "pipe"],
    });

    const state = createRunLaneState();
    const actions = [];
    const parser = new NdjsonParser(
      (value) => {
        if (!value || typeof value !== "object" || typeof value.kind !== "string") {
          return;
        }
        actions.push(...reduceLaneEvent(state, value, Date.now()));
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", reject);
    proc.on("close", () => {
      parser.end();
      resolve({ actions, state });
    });
  });
}
