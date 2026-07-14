// monitorBridgeWatchdog.test.mjs
// monitorBridgeWatchdog.ts(MonitorBridgeWatchdog)のユニットテスト。node:test で実行する。
// esbuild が "../src/monitorBridgeWatchdog"(拡張子なし)を monitorBridgeWatchdog.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorBridgeWatchdog } from "../src/monitorBridgeWatchdog";

function device(name, state) {
  return { id: name, name, platform: "ios", state, detail: "" };
}

/** テスト用ハーネス。posts/logs/jobs を配列に記録し、now/autoRepair/runActive を手元で操作できる。 */
function createHarness(options = {}) {
  const posts = [];
  const logs = [];
  const jobs = [];
  let currentTime = 0;
  let autoRepairEnabled = options.autoRepairEnabled ?? true;
  let runActive = options.runActive ?? false;

  const watchdog = new MonitorBridgeWatchdog({
    post: (message) => posts.push(message),
    log: (message) => logs.push(message),
    enqueueLifecycleJob: (job) => jobs.push(job),
    isAutoRepairEnabled: () => autoRepairEnabled,
    isAnyRunActive: () => runActive,
    now: () => currentTime,
  });

  return {
    watchdog,
    posts,
    logs,
    jobs,
    advance: (ms) => {
      currentTime += ms;
    },
    setRunActive: (value) => {
      runActive = value;
    },
  };
}

const COOLDOWN_MS = 3 * 60 * 1000;

test("最初から booted のデバイスは対象外(5回連続 booted でも何も post しない)", () => {
  const h = createHarness();
  for (let i = 0; i < 10; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.deepEqual(h.posts, []);
  assert.deepEqual(h.jobs, []);
});

test("connected 観測後、booted が連続5回で unresponsive を post+log する", () => {
  const h = createHarness({ autoRepairEnabled: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 4; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
    assert.deepEqual(h.posts, [], `${i + 1}回目では post しない`);
  }
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.posts, [{ type: "bridgeWatch", name: "Sim1", phase: "unresponsive" }]);
  assert.equal(h.logs.length, 1);

  // 閾値到達後も autoRepair 無効なら追加の post/job は発生しない(booted を観測し続けても冪等)。
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.posts, [{ type: "bridgeWatch", name: "Sim1", phase: "unresponsive" }]);
  assert.deepEqual(h.jobs, []);
});

test("5回未満の booted の後に connected へ戻れば streak がリセットされ post は発生しない", () => {
  const h = createHarness();
  h.watchdog.observe([device("Sim1", "connected")]);
  h.watchdog.observe([device("Sim1", "booted")]);
  h.watchdog.observe([device("Sim1", "booted")]);
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 4; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.deepEqual(h.posts, [], "4回連続(閾値未満)では unresponsive にならない");
});

test("autoRepairBridge 有効・実行中レーン無しなら device-up ジョブを投入し repairing を post する", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.deepEqual(h.posts, [
    { type: "bridgeWatch", name: "Sim1", phase: "unresponsive" },
    { type: "bridgeWatch", name: "Sim1", phase: "repairing" },
  ]);
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
});

test("実行中レーンがある間は自動修復を投入しない(レーン終了後に投入される)", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: true });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.deepEqual(h.posts, [{ type: "bridgeWatch", name: "Sim1", phase: "unresponsive" }]);
  assert.deepEqual(h.jobs, []);

  h.setRunActive(false);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
  assert.deepEqual(h.posts, [
    { type: "bridgeWatch", name: "Sim1", phase: "unresponsive" },
    { type: "bridgeWatch", name: "Sim1", phase: "repairing" },
  ]);
});

test("クールダウン中は再投入しない。クールダウン明けでまだ booted なら2回目を投入する", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.equal(h.jobs.length, 1);

  h.advance(COOLDOWN_MS - 1);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.equal(h.jobs.length, 1, "クールダウン中は追加投入しない");

  h.advance(2);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.equal(h.jobs.length, 2, "クールダウン明けで2回目を投入する");
  assert.deepEqual(h.posts.at(-1), { type: "bridgeWatch", name: "Sim1", phase: "repairing" });
});

test("2回試行してもクールダウン明けでまだ connected に戻らなければ failed を post+log し、以後投入しない", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]); // 2回目投入
  assert.equal(h.jobs.length, 2);

  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]); // 3回目は投入されず failed になる
  assert.equal(h.jobs.length, 2, "3回目は投入しない");
  assert.deepEqual(h.posts.at(-1), { type: "bridgeWatch", name: "Sim1", phase: "failed" });
  assert.equal(h.logs.length, 2, "unresponsive と failed でそれぞれ1行ログする");

  // failed 後はいくら booted を観測しても post/job が増えない。
  // (unresponsive + repairing×2 + failed の4件で以後増えない)
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.equal(h.jobs.length, 2);
  assert.equal(h.posts.length, 4);
});

test("connected を観測すると回復し ok を post、カウンタ・試行履歴がリセットされる", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]);
  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.posts.at(-1), { type: "bridgeWatch", name: "Sim1", phase: "failed" });

  h.watchdog.observe([device("Sim1", "connected")]);
  assert.deepEqual(h.posts.at(-1), { type: "bridgeWatch", name: "Sim1", phase: "ok" });

  // リセット後、再び5回連続 booted になれば新たに unresponsive〜repairing が発生する(履歴を引きずらない)。
  const postsBefore = h.posts.length;
  const jobsBefore = h.jobs.length;
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.deepEqual(h.posts.slice(postsBefore), [
    { type: "bridgeWatch", name: "Sim1", phase: "unresponsive" },
    { type: "bridgeWatch", name: "Sim1", phase: "repairing" },
  ]);
  assert.equal(h.jobs.length, jobsBefore + 1);
});

test("offline は streak をリセットするが failed/attemptCount は connected 観測まで保持する", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]);
  h.advance(COOLDOWN_MS);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.posts.at(-1), { type: "bridgeWatch", name: "Sim1", phase: "failed" });
  assert.equal(h.jobs.length, 2);

  h.watchdog.observe([device("Sim1", "offline")]);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.equal(h.jobs.length, 2, "failed 後は offline を挟んでも再投入しない");
  assert.equal(h.posts.at(-1).phase, "failed");
});

test("複数デバイスは独立して状態管理される", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected"), device("Sim2", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted"), device("Sim2", "connected")]);
  }
  assert.deepEqual(h.posts, [
    { type: "bridgeWatch", name: "Sim1", phase: "unresponsive" },
    { type: "bridgeWatch", name: "Sim1", phase: "repairing" },
  ]);
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
});
