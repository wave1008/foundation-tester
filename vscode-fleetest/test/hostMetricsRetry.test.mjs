// hostMetricsRetry.test.mjs
// host-metrics 子プロセスの再試行の判定(src/hostMetricsRetry.ts)。純粋関数なので spawn も
// タイマーも要らない。**定数はリテラルで固定する** —— 10分と3回は「旧バイナリへ ssh を
// 張り続けない」「飽和中に撃たない」の2つが根拠で、縮めるとどちらも壊れる。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  HOST_METRICS_GIVE_UP_RETRY_MS,
  HOST_METRICS_QUICK_FAILURE_LIMIT,
  HOST_METRICS_QUICK_FAILURE_MS,
  HOST_METRICS_RETRY_DELAY_MS,
  machineObservations,
  observationRevivalPlan,
  retryPlan,
} from "../src/hostMetricsRetry";

test("既定値はリテラルで固定する(諦めの間隔10分・連敗3回・早期終了10秒・通常5秒)", () => {
  assert.equal(HOST_METRICS_GIVE_UP_RETRY_MS, 600000, "10分。短くすると churn と空振りが戻る");
  assert.equal(HOST_METRICS_QUICK_FAILURE_LIMIT, 3);
  assert.equal(HOST_METRICS_QUICK_FAILURE_MS, 10000);
  assert.equal(HOST_METRICS_RETRY_DELAY_MS, 5000);
});

test("retryPlan: 早期終了が3回続いたら長い間隔へ落とす", () => {
  assert.deepEqual(retryPlan({ failureStreak: 0, elapsedMs: 100 }),
    { failureStreak: 1, delayMs: 5000, gaveUp: false });
  assert.deepEqual(retryPlan({ failureStreak: 1, elapsedMs: 100 }),
    { failureStreak: 2, delayMs: 5000, gaveUp: false });
  assert.deepEqual(retryPlan({ failureStreak: 2, elapsedMs: 100 }),
    { failureStreak: 3, delayMs: 600000, gaveUp: true });
});

test("retryPlan: 10秒以上生きてからの終了は正常運転(連敗を0に戻す)", () => {
  assert.deepEqual(retryPlan({ failureStreak: 2, elapsedMs: 10000 }),
    { failureStreak: 0, delayMs: 5000, gaveUp: false });
});

// ---- 「その機械が再び観測できるようになった」合図 ----

const device = (machine, state) => ({ machine, state });

test("machineObservations: unknown だけの機械は観測できていない(offline は観測できている)", () => {
  const observations = machineObservations([
    device("mac2", "unknown"),
    device("mac3", "offline"),
    device("mac4", "connected"),
  ]);
  assert.equal(observations.get("mac2"), "unobserved");
  // **unknown と offline を混ぜない** —— offline は「止まっていると分かる」= 観測できている
  assert.equal(observations.get("mac3"), "observed");
  assert.equal(observations.get("mac4"), "observed");
});

test("machineObservations: 手元(machine 無し)は含めない・1台でも観測できていれば観測できている", () => {
  const observations = machineObservations([
    { state: "connected" },
    { machine: "", state: "connected" },
    device("mac2", "unknown"),
    device("mac2", "booted"),
  ]);
  assert.deepEqual([...observations], [["mac2", "observed"]]);
});

test("observationRevivalPlan: 観測できない → 観測できる でだけ諦めを畳む", () => {
  assert.deepEqual(
    observationRevivalPlan({ before: "unobserved", now: "observed", gaveUp: true }),
    { foldGiveUp: true },
  );
  // 旧バイナリ相当: fanout の子も上がらないので台は unknown のまま = 合図が出ない
  assert.deepEqual(
    observationRevivalPlan({ before: "unobserved", now: "unobserved", gaveUp: true }),
    { foldGiveUp: false },
  );
  // 飽和相当: fanout は生きたまま host-metrics だけ落ちる = ずっと観測できている
  assert.deepEqual(
    observationRevivalPlan({ before: "observed", now: "observed", gaveUp: true }),
    { foldGiveUp: false },
  );
  // 初見(パネルを開いた直後)は遷移ではない —— 新しい機械の子は起動時にカウンタを畳む
  assert.deepEqual(
    observationRevivalPlan({ before: undefined, now: "observed", gaveUp: true }),
    { foldGiveUp: false },
  );
  // 諦めていない子は張り直さない(生きている子への二重起動を作らない)
  assert.deepEqual(
    observationRevivalPlan({ before: "unobserved", now: "observed", gaveUp: false }),
    { foldGiveUp: false },
  );
});
