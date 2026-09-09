// monitorBridgeWatchdog.test.mjs
// monitorBridgeWatchdog.ts(MonitorBridgeWatchdog)のユニットテスト。node:test で実行する。
// esbuild が "../src/monitorBridgeWatchdog"(拡張子なし)を monitorBridgeWatchdog.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorBridgeWatchdog } from "../src/monitorBridgeWatchdog";

function device(name, state, registered) {
  return { id: name, name, platform: "ios", state, detail: "", ...(registered === undefined ? {} : { registered }) };
}

/** 別の機械の同名デバイス(フリートでは通常の構成)。 */
function remoteDevice(name, state, host = "M1Max") {
  return { id: `ios:${host}/${name}`, name, platform: "ios", state, detail: "", machine: host };
}

/** テスト用ハーネス。posts/logs/jobs を配列に記録し、now/autoRepair/runActive を手元で操作できる。 */
function createHarness(options = {}) {
  const posts = [];
  const logs = [];
  const jobs = [];
  let currentTime = 0;
  let autoRepairEnabled = options.autoRepairEnabled ?? true;
  let runActive = options.runActive ?? false;
  let queueBusy = options.queueBusy ?? false;

  const watchdog = new MonitorBridgeWatchdog({
    post: (message) => posts.push(message),
    log: (message) => logs.push(message),
    enqueueLifecycleJob: (job) => jobs.push(job),
    isAutoRepairEnabled: () => autoRepairEnabled,
    isAnyRunActive: () => runActive,
    isDeviceLifecycleQueueBusy: () => queueBusy,
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
    setQueueBusy: (value) => {
      queueBusy = value;
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

test("未登録(registered:false)は connected→booted を繰り返しても post も修復 up も発生しない", () => {
  const h = createHarness();
  h.watchdog.observe([device("Sim1", "connected", false)]);
  for (let i = 0; i < 6; i += 1) {
    h.watchdog.observe([device("Sim1", "booted", false)]);
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

test("ライフサイクルキューが busy(一括起動/停止)の間は数えない・宣言しない", () => {
  const h = createHarness({ queueBusy: true });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  // 供給中の booted は「まだ起動しきっていない」だけ(実害 2026-09-09: 10秒後に xcuitest bridge
  // ready になる台へ「ブリッジ無応答」を出していた)。inRun と同じく streak ごと 0 に戻す。
  assert.deepEqual(h.posts, [], "busy 中は unresponsive を宣言しない");
  assert.deepEqual(h.logs, [], "誤検知の警告を出さない");
  assert.deepEqual(h.jobs, [], "busy 中は start-device を積まない");

  // busy が解けてから数え直す(閾値に届いて初めて検知し、同じ観測で修復を積む)
  h.setQueueBusy(false);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.ok(h.posts.some((p) => p.phase === "unresponsive"));
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
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

test("autoRepairBridge 有効・実行中レーン無しなら start-device ジョブを投入し repairing を post する", () => {
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

test("実機(kind: physical)は connected→booted を繰り返しても修復 up を積まない(実機のブリッジ起動は run とタイルのメニューだけ)", () => {
  const h = createHarness();
  const physical = { ...device("iPhone 13(実機)", "connected"), kind: "physical" };
  h.watchdog.observe([physical]);
  for (let i = 0; i < 10; i += 1) {
    h.watchdog.observe([{ ...physical, state: "booted" }]);
  }
  assert.deepEqual(h.jobs, []);
  assert.deepEqual(h.posts, []);
  // 同じ観測列でも仮想デバイスなら修復が積まれる(検査が生きている対照)
  const virtual = { ...device("Sim1", "connected"), kind: "virtual" };
  h.watchdog.observe([virtual]);
  for (let i = 0; i < 10; i += 1) {
    h.watchdog.observe([{ ...virtual, state: "booted" }]);
  }
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
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

// 別の機械の台は見ない。**修復手段が手元にしか効かない**のに加え、entries が name 単位なので
// 同名の台が2機にあると「向こうの connected が手元のハングを隠す」「向こうの booted が
// 手元の健全な台を再起動する」の両方が起きる(2026-08-17 のレビュー指摘)。
test("リモートのデバイスは観測しない(同名の手元の台と混線させない)", () => {
  const h = createHarness();
  // 手元の台が booted のまま張り付く = 本来なら修復が積まれる状況
  for (let i = 0; i < 6; i++) {
    h.watchdog.observe([device("Sim1", "connected")]);
    break;
  }
  h.jobs.length = 0;
  // ここで「向こうの Sim1 は connected」を毎回混ぜても、手元の booted 連続は途切れない
  for (let i = 0; i < 6; i++) {
    h.watchdog.observe([device("Sim1", "booted"), remoteDevice("Sim1", "connected")]);
    h.advance(60_000);
  }
  assert.ok(h.jobs.length > 0, "向こうの connected が手元のハングを隠してはいけない");
});

test("リモートのデバイスだけでは修復ジョブを積まない(別の機械は直せない)", () => {
  const h = createHarness();
  h.watchdog.observe([remoteDevice("Sim9", "connected")]);
  for (let i = 0; i < 6; i++) {
    h.watchdog.observe([remoteDevice("Sim9", "booted")]);
    h.advance(60_000);
  }
  assert.deepEqual(h.jobs, [], "手元の同名の台を巻き添えに再起動してしまう");
});

// **run の最中の台は修復しない**。inRun は RunLease 由来なので、CLI や別の機械から起こした
// run も含む(isAnyRunActive は拡張自身のレーンしか見ない)。run が自分でブリッジを供給し直す
// 間の booted に start-device を重ねると、run のブリッジを横から入れ替えることになる
// (monitorHealthWatchdog の inRun 保留と同じ規律)。
test("inRun の間は booted が連続しても unresponsive にも修復にもならず、解けたら通常どおり数え直す", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([{ ...device("Sim1", "booted"), inRun: true }]);
  }
  assert.deepEqual(h.jobs, [], "run の最中に start-device を積まない");
  assert.deepEqual(h.posts, [], "run 自身の供給中の booted を無応答と言わない");

  // inRun が解けた直後は 0 から数え直す(4回では閾値に届かない)
  for (let i = 0; i < 4; i += 1) {
    h.watchdog.observe([{ ...device("Sim1", "booted"), inRun: false }]);
  }
  assert.deepEqual(h.jobs, []);
  assert.deepEqual(h.posts, []);
  h.watchdog.observe([device("Sim1", "booted")]);
  assert.deepEqual(h.posts, [
    { type: "bridgeWatch", name: "Sim1", phase: "unresponsive" },
    { type: "bridgeWatch", name: "Sim1", phase: "repairing" },
  ]);
  assert.deepEqual(h.jobs, [{ kind: "device", name: "Sim1", op: "up" }]);
});

test("無応答検知の後に run が始まったら修復を保留し(ログは保留に入った1回だけ)、run が終わってから撃つ", () => {
  const h = createHarness({ autoRepairEnabled: true, runActive: false });
  h.watchdog.observe([device("Sim1", "connected")]);
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.equal(h.jobs.length, 1);
  h.advance(COOLDOWN_MS);
  const logsBefore = h.logs.length;
  for (let i = 0; i < 3; i += 1) {
    h.watchdog.observe([{ ...device("Sim1", "booted"), inRun: true }]);
  }
  assert.equal(h.jobs.length, 1, "run の最中はクールダウン明けでも2回目を積まない");
  assert.equal(h.logs.length - logsBefore, 1, "保留のログは毎サイクルではなく1回");
  assert.equal(h.posts.at(-1).phase, "repairing", "failed にも倒さない(attemptCount を動かさない)");

  // run が終わって booted が続けば2回目の修復(attemptCount は据え置きなので failed にはならない)
  for (let i = 0; i < 5; i += 1) {
    h.watchdog.observe([device("Sim1", "booted")]);
  }
  assert.equal(h.jobs.length, 2);
  assert.equal(h.posts.at(-1).phase, "repairing");
});
