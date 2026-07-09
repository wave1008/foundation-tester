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
