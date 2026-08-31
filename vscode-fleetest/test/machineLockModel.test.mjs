// machineLockModel.test.mjs
// リモート機の占有(dispatch.lock)の控え(src/machineLockModel.ts)。
// **「不明」と「空き」を混ぜない**のがこのモデルの要点 —— 破壊的操作の確認が
// 「走っている run は無い」と誤って請け合わないため。

import assert from "node:assert/strict";
import { test } from "node:test";
import { applyMachineLockEvent, isConfirmedHeld, occupiedMachines } from "../src/machineLockModel";
import { isMonitorEvent } from "../src/monitorDeviceModel";

const heldEvent = {
  kind: "monitorLock", machine: "M1Max", observed: true, held: true,
  issuer: "bob", issuerHost: "bob-mbp", acquiredAt: "2026-08-31T00:00:00Z", mine: false,
};

test("占有イベントは機械ごとに控える", () => {
  const locks = applyMachineLockEvent(new Map(), heldEvent);
  assert.equal(locks.get("M1Max").held, true);
  assert.equal(locks.get("M1Max").issuer, "bob");
  assert.deepEqual([...occupiedMachines(locks)], ["M1Max"]);
});

test("解放は控えを空きに更新する(控えは残る = 空きだと分かっている)", () => {
  const held = applyMachineLockEvent(new Map(), heldEvent);
  const free = applyMachineLockEvent(held, { ...heldEvent, held: false, issuer: undefined });
  assert.equal(free.get("M1Max").held, false);
  assert.equal(free.get("M1Max").observed, true);
  assert.deepEqual([...occupiedMachines(free)], []);
  assert.equal(isConfirmedHeld(free.get("M1Max")), false);
});

// 子が落ちたら観測の根拠が無い。**空きにはしない** —— 控えを消すと「一度も聞いていない機械」
// (= 配信してよい)と同じ扱いになり、run の最中に配信が再開する
test("observed:false は「不明」で、空きとして扱わない", () => {
  const held = applyMachineLockEvent(new Map(), heldEvent);
  const gone = applyMachineLockEvent(held, { ...heldEvent, observed: false, held: false });
  assert.equal(gone.get("M1Max").observed, false);
  assert.equal(gone.get("M1Max").held, true, "直前に分かっていた値は残す(不明と『空きだと分かっている』を混ぜない)");
  assert.deepEqual([...occupiedMachines(gone)], ["M1Max"], "分からない間は配信を畳んだままにする");
  assert.equal(isConfirmedHeld(gone.get("M1Max")), false,
    "**残した値を事実として出さない** —— 破壊的操作の確認も錠前も観測できているときだけ");
});

// 一度も聞いていない機械(旧ランナー)は控えに入らない = 従来どおり配信できる
test("控えに無い機械は配信を止めない", () => {
  assert.deepEqual([...occupiedMachines(new Map())], []);
  assert.equal(isConfirmedHeld(undefined), false);
});

test("machine の無いイベント(手元)は控えない", () => {
  const locks = applyMachineLockEvent(new Map(), { ...heldEvent, machine: undefined });
  assert.equal(locks.size, 0);
});

// 自分の run でも配信との干渉は同じなので、退避の対象からは外さない
test("自分の run でも占有として扱う", () => {
  const locks = applyMachineLockEvent(new Map(), { ...heldEvent, issuer: "alice", mine: true });
  assert.deepEqual([...occupiedMachines(locks)], ["M1Max"]);
});

test("monitorLock イベントの検証: 必須 bool 欠落は捨てる", () => {
  assert.equal(isMonitorEvent({ ...heldEvent }), true);
  assert.equal(isMonitorEvent({ kind: "monitorLock", machine: "M", observed: true, held: true }), false);
  assert.equal(isMonitorEvent({ kind: "monitorLock", observed: true, held: true, mine: false }), true,
    "machine 省略(手元)も形としては妥当");
  // 文字列でない issuer は落とす(丸ごと捨てずに欄だけ落とす = 表示が壊れない)
  const dirty = { ...heldEvent, issuer: 42 };
  assert.equal(isMonitorEvent(dirty), true);
  assert.equal(dirty.issuer, undefined);
});
