// runReducer.test.mjs
// runReducer.ts(reduceRunEvent)のユニットテスト。node:test で実行する。
// esbuild が "../src/runReducer"(拡張子なし)を runReducer.ts に解決してバンドルする。
//
// 末尾に、mock-runner.mjs を実際に spawn して NdjsonParser → reduceRunEvent に
// 通す統合テストを1本含む(cli.ts の onNdjsonValue と同じ配線を再現する)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import { createRunReducerState, reduceRunEvent } from "../src/runReducer";

// esbuild がこのテストを out-test/ にバンドルするため、import.meta.url はバンドル後の
// 場所を指す(= out-test/fixtures/ という存在しないディレクトリを指してしまう)。
// npm test は常に vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)
// ので、process.cwd() を基準に test/fixtures/ を解決する。
const MOCK_RUNNER = path.resolve(process.cwd(), "test", "fixtures", "mock-runner.mjs");

/** 複数イベントを1つの reducer 状態に順に適用し、発生したアクションを1配列にまとめて返す。 */
function feed(events, { nowMs = () => 1000 } = {}) {
  let state = createRunReducerState();
  const actions = [];
  let tick = 0;
  for (const event of events) {
    const now = typeof nowMs === "function" ? nowMs(tick) : nowMs;
    const result = reduceRunEvent(state, event, now);
    state = result.state;
    actions.push(...result.actions);
    tick += 1;
  }
  return actions;
}

test("全 passed: started → passed → end のアクション列になる", () => {
  const events = [
    { kind: "runStarted", total: 1 },
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "sceneStarted", scenario: "S.T1", scene: 1, sceneTitle: "シーン1" },
    {
      kind: "step",
      scenario: "S.T1",
      index: 1,
      description: "launch app",
      status: "passed",
      file: "a.swift",
      line: 1,
    },
    { kind: "sceneFinished", scenario: "S.T1", scene: 1, sceneTitle: "シーン1", passed: true },
    { kind: "scenarioFinished", scenario: "S.T1", passed: true, reportPath: "/tmp/r.md" },
    { kind: "runFinished", passed: 1, failed: 0 },
  ];
  const actions = feed(events, { nowMs: (tick) => (tick <= 1 ? 1000 : 1500) });

  assert.deepEqual(
    actions.filter((a) => a.type !== "output"),
    [
      { type: "started", scenario: "S.T1" },
      { type: "passed", scenario: "S.T1", durationMs: 500 },
      { type: "end", passed: 1, failed: 0 },
    ],
  );
});

test("step failed: TestMessage(text+location) が scenarioFinished(passed:false) の failed アクションに蓄積される", () => {
  const events = [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "sceneStarted", scenario: "S.T1", scene: 1, sceneTitle: "シーン1" },
    {
      kind: "step",
      scenario: "S.T1",
      index: 1,
      description: 'exist "#missing"',
      status: "failed",
      detail: "要素が見つかりません",
      file: "Projects/P/Scenarios/S.swift",
      line: 42,
    },
    { kind: "scenarioFinished", scenario: "S.T1", passed: false, reportPath: "/tmp/r.md" },
  ];
  const actions = feed(events);
  const failed = actions.find((a) => a.type === "failed");

  assert.ok(failed, "failed アクションが発生する");
  assert.equal(failed.scenario, "S.T1");
  assert.equal(failed.messages.length, 1);
  assert.equal(failed.messages[0].text, 'exist "#missing"\n要素が見つかりません');
  assert.deepEqual(failed.messages[0].location, {
    file: "Projects/P/Scenarios/S.swift",
    line: 42,
  });
});

test("scenarioFinished(passed:false) で失敗メッセージが1件も蓄積されていない場合はフォールバックの1件を渡す", () => {
  const events = [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "scenarioFinished", scenario: "S.T1", passed: false, reportPath: "/tmp/r.md" },
  ];
  const actions = feed(events);
  const failed = actions.find((a) => a.type === "failed");

  assert.ok(failed);
  assert.equal(failed.messages.length, 1);
  assert.match(failed.messages[0].text, /失敗しました/);
});

test("skipped ステップを含んでいてもシナリオ自体は passed になる", () => {
  const events = [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    {
      kind: "step",
      scenario: "S.T1",
      index: 1,
      description: 'tap "#opt" (optional)',
      status: "skipped",
      detail: "任意ステップをスキップ",
    },
    { kind: "scenarioFinished", scenario: "S.T1", passed: true },
  ];
  const actions = feed(events);

  assert.ok(actions.some((a) => a.type === "passed" && a.scenario === "S.T1"));
  assert.ok(!actions.some((a) => a.type === "failed"));
  // スキップの情報は output として出力される(⚠️ マーク)
  assert.ok(actions.some((a) => a.type === "output" && a.text.includes("⚠️")));
});

test("複数シナリオ: それぞれ独立して started/passed/failed が発生する", () => {
  const events = [
    { kind: "runStarted", total: 2 },
    { kind: "scenarioStarted", scenario: "S.T1", title: "1つ目" },
    { kind: "scenarioFinished", scenario: "S.T1", passed: true },
    { kind: "scenarioStarted", scenario: "S.T2", title: "2つ目" },
    {
      kind: "step",
      scenario: "S.T2",
      index: 1,
      description: "fail step",
      status: "failed",
      detail: "NG",
    },
    { kind: "scenarioFinished", scenario: "S.T2", passed: false },
    { kind: "runFinished", passed: 1, failed: 1 },
  ];
  const actions = feed(events);

  assert.deepEqual(
    actions.filter((a) => a.type === "started").map((a) => a.scenario),
    ["S.T1", "S.T2"],
  );
  assert.ok(actions.some((a) => a.type === "passed" && a.scenario === "S.T1"));
  assert.ok(actions.some((a) => a.type === "failed" && a.scenario === "S.T2"));
  assert.ok(actions.some((a) => a.type === "end"));
});

test("workersReady: workers アクションが発生する(並列実行時のみ)", () => {
  const workers = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "port 8127" },
    { id: "ios:シミュ2", name: "シミュ2", platform: "ios", detail: "port 8128" },
  ];
  const actions = feed([{ kind: "runStarted", total: 2 }, { kind: "workersReady", workers }]);
  const workersAction = actions.find((a) => a.type === "workers");

  assert.ok(workersAction);
  assert.deepEqual(workersAction.workers, workers);
});

test("並列実行: 2シナリオのイベントが交互に混在しても、それぞれ独立して正しい終了アクションになる", () => {
  const workers = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "port 8127" },
    { id: "ios:シミュ2", name: "シミュ2", platform: "ios", detail: "port 8128" },
  ];
  const events = [
    { kind: "runStarted", total: 2 },
    { kind: "workersReady", workers },
    // シナリオA(worker1)とシナリオB(worker2)のイベントを1件ずつ交互に並べる(実際の並列実行を模す)
    { kind: "scenarioStarted", scenario: "S.A", title: "A", worker: "ios:シミュ1" },
    { kind: "scenarioStarted", scenario: "S.B", title: "B", worker: "ios:シミュ2" },
    {
      kind: "step",
      scenario: "S.A",
      index: 1,
      description: "launch app",
      status: "passed",
      worker: "ios:シミュ1",
    },
    {
      kind: "step",
      scenario: "S.B",
      index: 1,
      description: "fail step",
      status: "failed",
      detail: "NG",
      worker: "ios:シミュ2",
    },
    { kind: "scenarioFinished", scenario: "S.B", passed: false, worker: "ios:シミュ2" },
    { kind: "scenarioFinished", scenario: "S.A", passed: true, worker: "ios:シミュ1" },
    { kind: "runFinished", passed: 1, failed: 1 },
  ];
  const actions = feed(events);

  // 交互に混在していても、シナリオごとの started/passed/failed が正しく独立して発生する
  assert.deepEqual(
    actions.filter((a) => a.type === "started").map((a) => a.scenario).sort(),
    ["S.A", "S.B"],
  );
  const passedAction = actions.find((a) => a.type === "passed");
  assert.equal(passedAction.scenario, "S.A");
  const failedAction = actions.find((a) => a.type === "failed");
  assert.equal(failedAction.scenario, "S.B");
  assert.equal(failedAction.messages[0].text, "fail step\nNG");
  assert.ok(actions.some((a) => a.type === "end" && a.passed === 1 && a.failed === 1));

  // output アクションに worker が伝播している(runHandler.ts の [デバイス名] プレフィックスの元)
  const scenarioStartedOutputs = actions.filter(
    (a) => a.type === "output" && a.text.startsWith("▶ A") ,
  );
  assert.equal(scenarioStartedOutputs.length, 1);
  assert.equal(scenarioStartedOutputs[0].worker, "ios:シミュ1");
  const bOutputs = actions.filter((a) => a.type === "output" && a.text.startsWith("▶ B"));
  assert.equal(bOutputs.length, 1);
  assert.equal(bOutputs[0].worker, "ios:シミュ2");
});

test("worker フィールドが無いイベント(逐次実行)の output アクションは worker が undefined", () => {
  const actions = feed([{ kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" }]);
  const output = actions.find((a) => a.type === "output" && a.scenario === "S.T1");
  assert.equal(output.worker, undefined);
});

test("統合: mock-runner.mjs(parallel パターン)の出力から、シナリオ毎の終了アクションと workers アクションが得られる", async () => {
  const actions = await runMockThroughPipeline([
    "--pattern",
    "parallel",
    "--scenario",
    "並列.A",
    "--scenario",
    "並列.B",
  ]);

  const workersAction = actions.find((a) => a.type === "workers");
  assert.ok(workersAction, "workers アクションが発生する");
  assert.deepEqual(
    workersAction.workers.map((w) => w.id),
    ["ios:シミュ1", "ios:シミュ2"],
  );

  assert.deepEqual(
    actions.filter((a) => a.type === "started").map((a) => a.scenario).sort(),
    ["並列.A", "並列.B"],
  );
  const passed = actions.find((a) => a.type === "passed");
  assert.equal(passed.scenario, "並列.A");
  const failed = actions.find((a) => a.type === "failed");
  assert.equal(failed.scenario, "並列.B");

  const end = actions.find((a) => a.type === "end");
  assert.deepEqual(end, { type: "end", passed: 1, failed: 1 });

  // worker プレフィックスの元になる情報が output に伝播している
  const workerTaggedOutputs = actions.filter((a) => a.type === "output" && a.worker != null);
  assert.ok(workerTaggedOutputs.length > 0);
  assert.ok(workerTaggedOutputs.every((a) => a.worker === "ios:シミュ1" || a.worker === "ios:シミュ2"));
});

test("runFinished 前に EOF(突然死): end アクションが発生しない(呼び出し側が errored 判定に使う)", () => {
  const events = [
    { kind: "runStarted", total: 1 },
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "sceneStarted", scenario: "S.T1", scene: 1, sceneTitle: "シーン1" },
    {
      kind: "step",
      scenario: "S.T1",
      index: 1,
      description: "launch app",
      status: "passed",
    },
    // ここでプロセスが死んだ想定(scenarioFinished/runFinished が来ない)
  ];
  const actions = feed(events);

  assert.ok(!actions.some((a) => a.type === "end"));
  assert.ok(!actions.some((a) => a.type === "passed" || a.type === "failed"));
  assert.ok(actions.some((a) => a.type === "started" && a.scenario === "S.T1"));
});

test("非JSON/未知の値は無視される(例外を投げず、アクションも発生しない)", () => {
  let state = createRunReducerState();

  const r1 = reduceRunEvent(state, { foo: "bar" }, 0); // kind が無い
  state = r1.state;
  assert.deepEqual(r1.actions, []);

  const r2 = reduceRunEvent(state, { kind: 123 }, 0); // kind が文字列でない
  state = r2.state;
  assert.deepEqual(r2.actions, []);

  const r3 = reduceRunEvent(state, { kind: "unknownKindFromFuture" }, 0); // 未知の kind
  state = r3.state;
  assert.deepEqual(r3.actions, []);

  const r4 = reduceRunEvent(state, null, 0);
  assert.deepEqual(r4.actions, []);

  const r5 = reduceRunEvent(state, "not an object", 0);
  assert.deepEqual(r5.actions, []);
});

test("wipeStatus は isRunEvent には該当するが Test Explorer 出力へのアクションは発生しない", () => {
  const state = createRunReducerState();
  const r = reduceRunEvent(state, { kind: "wipeStatus", device: "エミュ1", phase: "stopping" }, 0);
  assert.deepEqual(r.actions, []);
});

test("fixSuggestion は出力アクションになる(location 付き)", () => {
  const events = [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    {
      kind: "fixSuggestion",
      scenario: "S.T1",
      description: 'tap "#old_id"',
      detail: "ロケータが変化した可能性があります",
      file: "Projects/P/Scenarios/S.swift",
      line: 20,
      oldSelector: "#old_id",
      newSelector: "#new_id",
    },
  ];
  const actions = feed(events);
  const suggestion = actions.find(
    (a) => a.type === "output" && a.text.includes("修正提案"),
  );

  assert.ok(suggestion);
  assert.equal(suggestion.scenario, "S.T1");
  assert.deepEqual(suggestion.location, { file: "Projects/P/Scenarios/S.swift", line: 20 });
  assert.ok(actions.some((a) => a.type === "output" && a.text.includes("#old_id → #new_id")));
});

test("log イベントは output アクションになり、空メッセージは無視される", () => {
  const events = [
    { kind: "scenarioStarted", scenario: "S.T1", title: "タイトル" },
    { kind: "log", scenario: "S.T1", message: "デバッグ出力" },
    { kind: "log", scenario: "S.T1", message: "" },
  ];
  const actions = feed(events);
  const logOutputs = actions.filter((a) => a.type === "output" && a.text.includes("デバッグ出力"));

  assert.equal(logOutputs.length, 1);
});

test("統合: mock-runner.mjs(success パターン)の出力を NdjsonParser → reduceRunEvent に通すと started→passed→end の順になる", async () => {
  const actions = await runMockThroughPipeline(["--pattern", "success", "--scenario", "統合.T1"]);
  const significant = actions.filter((a) => a.type !== "output");

  assert.equal(significant.length, 3);
  assert.equal(significant[0].type, "started");
  assert.equal(significant[0].scenario, "統合.T1");
  assert.equal(significant[1].type, "passed");
  assert.equal(significant[1].scenario, "統合.T1");
  assert.equal(significant[2].type, "end");
  assert.equal(significant[2].passed, 1);
  assert.equal(significant[2].failed, 0);
});

test("統合: mock-runner.mjs(nonjson パターン)は非JSON行を無視しつつ最後まで処理できる", async () => {
  const actions = await runMockThroughPipeline(["--pattern", "nonjson", "--scenario", "統合.T2"]);
  const significant = actions.filter((a) => a.type !== "output");

  assert.deepEqual(
    significant.map((a) => a.type),
    ["started", "passed", "end"],
  );
});

test("統合: mock-runner.mjs(crash パターン)は runFinished を出さずに異常終了する(呼び出し側の errored 判定材料になる)", async () => {
  const actions = await runMockThroughPipeline(["--pattern", "crash", "--scenario", "統合.T3"]);
  const significant = actions.filter((a) => a.type !== "output");

  assert.deepEqual(
    significant.map((a) => a.type),
    ["started"],
  );
});

/**
 * mock-runner.mjs を spawn し、stdout を NdjsonParser → reduceRunEvent に通して
 * 発生したアクション全体を返す(cli.ts の execute() が組む配線の縮小版)。
 */
function runMockThroughPipeline(mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_RUNNER, ...mockArgs], {
      cwd: path.dirname(MOCK_RUNNER),
      stdio: ["ignore", "pipe", "pipe"],
    });

    let state = createRunReducerState();
    const actions = [];
    const parser = new NdjsonParser(
      (value) => {
        const result = reduceRunEvent(state, value, Date.now());
        state = result.state;
        actions.push(...result.actions);
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外。cli.ts では onLog に渡る)
      },
    );

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", reject);
    proc.on("close", () => {
      parser.end();
      resolve(actions);
    });
  });
}

test("scenarioRequeued は出力行と requeued アクション(待機中へ戻す)を発生させる", () => {
  const state = createRunReducerState();
  const r = reduceRunEvent(state, {
    kind: "scenarioRequeued", scenario: "Foo.S0010", worker: "ios:シム1",
    reason: "ブリッジ接続不能", attempt: 1, limit: 2,
  }, 0);
  assert.equal(r.actions.length, 2);
  assert.equal(r.actions[0].type, "output");
  assert.ok(r.actions[0].text.includes("🔁"));
  assert.ok(r.actions[0].text.includes("(1/2)"));
  assert.deepEqual(r.actions[1], { type: "requeued", scenario: "Foo.S0010" });
});
