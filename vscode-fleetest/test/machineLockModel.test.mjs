// machineLockModel.test.mjs
// 機械(手元を含む)の占有(dispatch.lock)の控え(src/machineLockModel.ts)。
// **「不明」と「空き」を混ぜない**のがこのモデルの要点 —— 破壊的操作の確認が
// 「走っている run は無い」と誤って請け合わないため。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  applyMachineLockEvent, bulkDownGate, isConfirmedHeld, localDevicesInRun, occupiedMachines, streamFoldMachines, sweepRefusalDetail,
} from "../src/machineLockModel";
import { LOCAL_MACHINE_KEY } from "../src/runBoardModel";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
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

// **machine 欠落 = 手元**(monitorRuns / monitorDevices と同じ綴り)。手元も dispatch.lock を
// 取るので捨てない —— 捨てていた頃は手元の run 中に錠前が出ず、他人がこの Mac へディスパッチ
// していても配信が畳まれなかった
test("machine の無いイベント(手元)は LOCAL_MACHINE_KEY で控える", () => {
  const locks = applyMachineLockEvent(new Map(), { ...heldEvent, machine: undefined });
  assert.deepEqual([...locks.keys()], [LOCAL_MACHINE_KEY]);
  assert.equal(locks.get(LOCAL_MACHINE_KEY).held, true);
  assert.equal(locks.get(LOCAL_MACHINE_KEY).issuer, "bob");
  assert.deepEqual([...occupiedMachines(locks)], [LOCAL_MACHINE_KEY]);
  // observed:false(監視プロセスが落ちた)も手元の控えへ畳む = 不明へ戻す
  const gone = applyMachineLockEvent(locks, { ...heldEvent, machine: undefined, observed: false, held: false });
  assert.equal(gone.get(LOCAL_MACHINE_KEY).observed, false);
  assert.equal(gone.get(LOCAL_MACHINE_KEY).held, true, "直前に分かっていた値は残す");
});

// **3ケースを等号で固定する**(この経路は手元の占有を配るまで1度も通っていなかった)。
// ①自分の run 中の手元は畳まない(ユーザー決定 2026-09-17「自分の run のぶんはライブ更新で
// 利用者が選ぶ」)②他人がこの Mac へディスパッチしている手元は畳む ③ライブ更新 OFF は全台畳む
test("streamFoldMachines: 手元も同じ規則(自分の run は畳まない・他人の run は畳む・OFF は全台)", () => {
  const localMine = applyMachineLockEvent(
    new Map(), { ...heldEvent, machine: undefined, issuer: "alice", mine: true });
  assert.deepEqual([...streamFoldMachines(localMine, true)], [],
    "自分の run 中の手元は畳まない");

  const localOther = applyMachineLockEvent(
    new Map(), { ...heldEvent, machine: undefined, issuer: "bob", mine: false });
  assert.deepEqual([...streamFoldMachines(localOther, true)], [LOCAL_MACHINE_KEY],
    "他人がこの Mac へディスパッチして保持している間は畳む");

  let both = applyMachineLockEvent(new Map(), { ...heldEvent, machine: undefined, issuer: "alice", mine: true });
  both = applyMachineLockEvent(both, { ...heldEvent, machine: "M1Max", issuer: "alice", mine: true });
  assert.deepEqual([...streamFoldMachines(both, false)].sort(), [LOCAL_MACHINE_KEY, "M1Max"].sort(),
    "ライブ更新 OFF は保持者を問わず全台畳む(手元も)");
});

// 自分の run でも配信との干渉は同じなので、退避の対象からは外さない
test("自分の run でも占有として扱う", () => {
  const locks = applyMachineLockEvent(new Map(), { ...heldEvent, issuer: "alice", mine: true });
  assert.deepEqual([...occupiedMachines(locks)], ["M1Max"]);
});

// 「画面更新」チェックボックス: OFF は保持者を問わず畳む / ON は他人の run と不明だけ畳む
test("streamFoldMachines: OFF は自分の run も畳み、ON は他人の run と観測できない機械だけ畳む", () => {
  let locks = applyMachineLockEvent(new Map(), { ...heldEvent, machine: "Mine", issuer: "alice", mine: true });
  locks = applyMachineLockEvent(locks, { ...heldEvent, machine: "Other" });
  locks = applyMachineLockEvent(locks, { ...heldEvent, machine: "Free", held: false, issuer: undefined });
  locks = applyMachineLockEvent(locks, { ...heldEvent, machine: "Lost", mine: true });
  locks = applyMachineLockEvent(locks, { ...heldEvent, machine: "Lost", observed: false, held: false, mine: true });
  assert.deepEqual([...streamFoldMachines(locks, false)].sort(), ["Lost", "Mine", "Other"]);
  assert.deepEqual([...streamFoldMachines(locks, true)].sort(), ["Lost", "Other"],
    "ON でも他人の run は配信で赤くしない・保持者が分からない機械は畳んだまま");
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

// ---- 「全て終了」の門(手元の run)----

const dev = (name, extra) => ({
  id: name, name, platform: "ios", state: "connected", detail: "", kind: "virtual", ...extra,
});

test("手元で run 中の台だけを挙げる(リモートの台・run していない台は挙げない)", () => {
  const devices = [
    dev("local-busy", { inRun: true }),
    dev("local-idle", { inRun: false }),
    dev("remote-busy", { inRun: true, machine: "M1Max" }),
    dev("local-unknown", {}),
  ];
  assert.deepEqual(localDevicesInRun(devices), ["local-busy"]);
  assert.deepEqual(localDevicesInRun(undefined), [], "未観測は黙る(CLI の門が最後に断る)");
});

test("プロファイル未選択(全掃討)で手元の run があれば撃たない —— リモートの占有より先に言う", () => {
  const gate = bulkDownGate({
    profileSelected: false, localInRun: ["iPhone A"], occupied: [{ machine: "M1Max", issuer: "bob" }],
  });
  assert.deepEqual(gate, { kind: "blockedByLocalRun", names: ["iPhone A"] });
});

test("プロファイル選択時は手元の run で止めない(CLI が使用中の台だけ飛ばす)", () => {
  assert.deepEqual(
    bulkDownGate({ profileSelected: true, localInRun: ["iPhone A"], occupied: [] }),
    { kind: "proceed" });
  assert.deepEqual(
    bulkDownGate({ profileSelected: true, localInRun: ["iPhone A"], occupied: [{ machine: "M1Max" }] }),
    { kind: "confirmOccupied", holders: [{ machine: "M1Max" }] });
});

test("何も走っていなければ確認を挟まない", () => {
  assert.deepEqual(bulkDownGate({ profileSelected: false, localInRun: [], occupied: [] }), { kind: "proceed" });
});

test("CLI の拒否行だけを拾う", () => {
  const line = "❌ refusing to shut everything down: a running fleetest run is using X (held by pid 1). Wait.";
  assert.equal(sweepRefusalDetail(line),
    "refusing to shut everything down: a running fleetest run is using X (held by pid 1). Wait.");
  assert.equal(sweepRefusalDetail("[M1Max] " + line), undefined, "リモートの子の中継行は手元の拒否ではない");
  assert.equal(sweepRefusalDetail("✅ All simulators shut down"), undefined);
});

test("拒否の文言は Swift 側(DeviceBooter.sweepRefusal)と一致する", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const swift = readFileSync(join(here, "../../Sources/FTAndroid/DeviceBooter.swift"), "utf8");
  assert.ok(swift.includes('"refusing to shut everything down: '),
    "Swift の文言を変えたら sweepRefusalDetail の正規表現も直す");
  assert.ok(readFileSync(join(here, "../../Sources/fleetest/DevicesCommand.swift"), "utf8")
    .includes('ConsoleOut.out("❌ \\(refusal)")'), "拒否行は ❌ 付きで stdout へ出す");
});

test("「全て終了」は門を通し、CLI の拒否は通知で見せる(配線)", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const panel = readFileSync(join(here, "../src/monitorPanel.ts"), "utf8");
  const body = panel.slice(panel.indexOf("private async confirmThenBulkDown"));
  assert.ok(body.indexOf("bulkDownGate(") >= 0
    && body.indexOf("bulkDownGate(") < body.indexOf("enqueueLifecycleJob"),
    "enqueue の前に bulkDownGate を通す");
  const blockedStart = body.indexOf('if (gate.kind === "blockedByLocalRun")');
  const blockedBranch = body.slice(blockedStart, body.indexOf("if (gate.kind", blockedStart + 1));
  assert.ok(blockedStart >= 0 && /\breturn;/.test(blockedBranch),
    "手元の run で止めるときは、その分岐の中で抜けて enqueue しない");
  const ops = readFileSync(join(here, "../src/monitorDeviceOps.ts"), "utf8");
  assert.ok(ops.includes("sweepRefusalDetail(line)") && ops.includes('t("deviceOps.bulkDownRefused"'),
    "全掃討の拒否行を拾って通知する");
});
