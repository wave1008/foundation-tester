// monitorBridgeLogRotation.test.mjs
// monitorBridgeLogRotation.ts(MonitorBridgeLogRotation)のユニットテスト。node:test で実行する。
// esbuild が "../src/monitorBridgeLogRotation"(拡張子なし)を monitorBridgeLogRotation.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorBridgeLogRotation } from "../src/monitorBridgeLogRotation";

function candidate(overrides = {}) {
  return {
    deviceId: "ios:Sim1",
    name: "Sim1",
    port: 8100,
    bundleBytes: 3_000_000_000,
    usageBytes: 2_700_000_000,
    limitBytes: 2_500_000_000,
    ...overrides,
  };
}

/** 別デバイス(クールダウンが deviceId 単位であることの対照)。 */
function candidate2() {
  return candidate({ deviceId: "ios:Sim2", name: "Sim2" });
}

/** テスト用ハーネス。posts の代わりに jobs/logs を配列に記録し、now/runActive/queueBusy を手元で操作できる。 */
function createHarness(options = {}) {
  const logs = [];
  const jobs = [];
  let currentTime = 0;
  let runActive = options.runActive ?? false;
  let queueBusy = options.queueBusy ?? false;

  const rotation = new MonitorBridgeLogRotation({
    log: (message) => logs.push(message),
    enqueueLifecycleJob: (job) => jobs.push(job),
    isAnyRunActive: () => runActive,
    isDeviceLifecycleQueueBusy: () => queueBusy,
    now: () => currentTime,
  });

  return {
    rotation,
    logs,
    jobs,
    advance: (ms) => {
      currentTime += ms;
    },
    setRunActive: (value) => {
      runActive = value;
    },
    setQueueBusy: (value) => {
      queueBusy = value;
    },
  };
}

const COOLDOWN_MS = 20 * 60 * 1000;

test("候補ありで busy/run 無しなら restartBridge ジョブを積み、ログを1行残す", () => {
  const h = createHarness();
  h.rotation.observe(candidate());
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "restartBridge" }]);
  assert.equal(h.logs.length, 1);
  assert.ok(h.logs[0].includes("Sim1"), "ログにデバイス名を含む");
});

test("candidate:null は何もしない", () => {
  const h = createHarness();
  h.rotation.observe(null);
  assert.deepEqual(h.jobs, []);
  assert.deepEqual(h.logs, []);
});

test("実行中レーンがある間は投入しない(レーン終了後に再評価で投入される)", () => {
  const h = createHarness({ runActive: true });
  h.rotation.observe(candidate());
  assert.deepEqual(h.jobs, [], "run 中は撃たない");

  h.setRunActive(false);
  h.rotation.reevaluate();
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "restartBridge" }],
    "run が終わったら再評価で拾い直す");
});

test("デバイスライフサイクルキューが busy の間は投入しない(busy 解除後に再評価で投入される)", () => {
  const h = createHarness({ queueBusy: true });
  h.rotation.observe(candidate());
  assert.deepEqual(h.jobs, [], "busy 中は撃たない");

  h.setQueueBusy(false);
  h.rotation.reevaluate();
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "restartBridge" }],
    "busy が解けたら再評価で拾い直す");
});

test("machine 付きの candidate は無視する(手元へ撃たない・直近候補も更新しない)", () => {
  const h = createHarness();
  h.rotation.observe(candidate({ machine: "M1Max" }));
  assert.deepEqual(h.jobs, [], "リモートの candidate が万一届いても手元に撃たない");

  // 直近の候補として記録もしない = 後から reevaluate しても撃たれない
  h.rotation.reevaluate();
  assert.deepEqual(h.jobs, []);
});

test("クールダウン中は再投入しない。クールダウン明けに再度撃つ", () => {
  const h = createHarness();
  h.rotation.observe(candidate());
  assert.equal(h.jobs.length, 1);

  // 同じ候補が再度届いても(周期の再送・断られた場合の再挑戦待ち)クールダウン中は撃たない
  h.advance(COOLDOWN_MS - 1);
  h.rotation.observe(candidate());
  assert.equal(h.jobs.length, 1, "クールダウン中は追加投入しない");

  h.advance(2);
  h.rotation.observe(candidate());
  assert.equal(h.jobs.length, 2, "クールダウン明けで2回目を投入する");
});

test("クールダウンは deviceId 単位(別デバイスは独立して即時投入できる)", () => {
  const h = createHarness();
  h.rotation.observe(candidate());
  assert.equal(h.jobs.length, 1);

  h.rotation.observe(candidate2());
  assert.deepEqual(h.jobs, [
    { kind: "device", name: "Sim1", op: "restartBridge" },
    { kind: "device", name: "Sim2", op: "restartBridge" },
  ], "別デバイスのクールダウンは互いに影響しない");
});

test("建て直しが断られた(busy)場合も、クールダウン後に再挑戦する", () => {
  const h = createHarness();
  h.rotation.observe(candidate());
  assert.equal(h.jobs.length, 1);

  // 断られる状況を作ってからクールダウン明けの再評価を通す(busy 中は積まない)
  h.setQueueBusy(true);
  h.advance(COOLDOWN_MS);
  h.rotation.reevaluate();
  assert.equal(h.jobs.length, 1, "busy の間はクールダウン明けでも撃たない");

  h.setQueueBusy(false);
  h.rotation.reevaluate();
  assert.equal(h.jobs.length, 2, "busy が解けたクールダウン明けの再評価で再挑戦する");
});

test("撃てなかった候補(busy)を保持し、状況が変わった後の再評価で1回だけ拾う(二重投入しない)", () => {
  const h = createHarness({ queueBusy: true });
  h.rotation.observe(candidate());
  h.rotation.reevaluate();
  h.rotation.reevaluate();
  assert.deepEqual(h.jobs, [], "busy の間は何度再評価しても撃たない");

  h.setQueueBusy(false);
  h.rotation.reevaluate();
  h.rotation.reevaluate();
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "restartBridge" }],
    "busy 解除後の再評価で1回だけ投入し、以後はクールダウンで抑止される");
});
