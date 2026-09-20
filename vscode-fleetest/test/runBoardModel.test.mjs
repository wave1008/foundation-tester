// runBoardModel.test.mjs
// run ボード(フリート横断の実行状況。docs/design.md §18)の純粋ロジック(src/runBoardModel.ts)。
// machineLockModel.test.mjs と同じ方針: 「不明」「空き」「実行中」の3値を混ぜないこと・
// observed:false で控えを消さないことを中心に見る。末尾で isMonitorEvent/toWebviewMessage の
// "monitorRuns" 往復(型検査の効かない webview 境界)も縛る。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  applyMonitorRunsEvent,
  buildRunGroups,
  liveElapsedSeconds,
  liveRemaining,
  LOCAL_MACHINE_KEY,
  machineRunStatus,
} from "../src/runBoardModel";
import { isMonitorEvent } from "../src/monitorDeviceModel";
import { toWebviewMessage } from "../src/monitorModel";

// **`remaining`(レーンごとの残り本数)は持たない**(FTCore.RunProgressLane の契約。
// shared dispatch のレーンは同じキューを共有するので、レーン別の残数は誤読を招く)。
function lane(overrides) {
  return {
    key: "UDID-1", name: "iPhone 17-01", platform: "ios",
    scenario: "05_検索", scenarioElapsedSeconds: 72,
    ...overrides,
  };
}

function run(overrides) {
  return {
    pid: 41233, runID: "run-1", issuer: undefined, mine: true,
    project: "ec-mobile", profile: "ios-smoke",
    elapsedSeconds: 261, total: 12, done: 7, failed: 2,
    lanes: [lane()],
    ...overrides,
  };
}

// ---- applyMonitorRunsEvent -------------------------------------------------------------------

test("machine 欠落(手元)は LOCAL_MACHINE_KEY に控え、run の machine は undefined のまま", () => {
  const state = applyMonitorRunsEvent(new Map(), { observed: true, runs: [run()] });
  const entry = state.get(LOCAL_MACHINE_KEY);
  assert.equal(entry.observed, true);
  assert.equal(entry.runs.length, 1);
  assert.equal(entry.runs[0].machine, undefined);
});

test("observed:false は控えを消さない(runs は直前のまま残る)が、状態は「不明」に落ちる", () => {
  const seeded = applyMonitorRunsEvent(new Map(), { machine: "M1Max", observed: true, runs: [run()] });
  const lost = applyMonitorRunsEvent(seeded, { machine: "M1Max", observed: false, runs: [] });
  const entry = lost.get("M1Max");
  assert.equal(entry.observed, false);
  assert.equal(entry.runs.length, 1, "直前の一覧は残す(『不明』と『無い』を混ぜない)");
  assert.equal(machineRunStatus(lost, "M1Max"), "unknown",
    "残した runs があっても unobserved なら unknown(スタブ値を実行中と言わない)");
});

test("空き・実行中・不明の3値が混ざらない", () => {
  let state = applyMonitorRunsEvent(new Map(), { machine: "Idle", observed: true, runs: [] });
  state = applyMonitorRunsEvent(state, { machine: "Busy", observed: true, runs: [run()] });
  // "Ghost" は一度も monitorRuns を受けていない(控えそのものが無い)
  assert.equal(machineRunStatus(state, "Idle"), "idle");
  assert.equal(machineRunStatus(state, "Busy"), "running");
  assert.equal(machineRunStatus(state, "Ghost"), "unknown");
});

// ---- buildRunGroups ---------------------------------------------------------------------------

test("runGroup を共有する run は1行に束ね、進捗と失敗数を合算する", () => {
  let state = applyMonitorRunsEvent(new Map(), {
    machine: "M1Max",
    observed: true,
    runs: [run({ runID: "run-a", runGroup: "grp-1", total: 12, done: 7, failed: 2, elapsedSeconds: 100 })],
  });
  state = applyMonitorRunsEvent(state, {
    machine: "M1Ultra",
    observed: true,
    runs: [run({ runID: "run-b", runGroup: "grp-1", total: 20, done: 3, failed: 0, elapsedSeconds: 150 })],
  });
  const groups = buildRunGroups(state);
  assert.equal(groups.length, 1, "runGroup が同じ2 run は1行");
  const [g] = groups;
  assert.equal(g.groupKey, "grp-1");
  assert.equal(g.total, 32);
  assert.equal(g.done, 10);
  assert.equal(g.failed, 2);
  assert.equal(g.elapsedSeconds, 150, "経過は束ねた中の最大");
  assert.equal(g.runs.length, 2);
  assert.deepEqual(g.runs.map((r) => r.machine), ["M1Max", "M1Ultra"], "machine 昇順");
});

test("runGroup の無い run はそれ自身で1グループ(runID が鍵)", () => {
  const state = applyMonitorRunsEvent(new Map(), {
    observed: true,
    runs: [run({ runID: "solo-1" }), run({ runID: "solo-2", pid: 999 })],
  });
  const groups = buildRunGroups(state);
  assert.equal(groups.length, 2);
  assert.deepEqual(groups.map((g) => g.groupKey).sort(), ["solo-1", "solo-2"]);
});

// FTCore.RunProgressRecord.runID は --dry-run/--debug 等では nil になりうる(RunRecorder が無い経路)。
test("runGroup も runID も無い run は machine つきの pid が鍵になる", () => {
  const state = applyMonitorRunsEvent(new Map(), {
    observed: true,
    runs: [run({ runID: undefined, runGroup: undefined, pid: 555 })],
  });
  const groups = buildRunGroups(state);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].groupKey, "#555", "手元(machine 無し)は空の名前空間");
});

// pid は機械ごとの番号なので、名前空間を切らないと別々の run が1行に束ねられて進捗が合算される。
test("pid しか鍵が無い run は、別の機械の同じ pid と束ねない", () => {
  let state = applyMonitorRunsEvent(new Map(), {
    machine: "M1Max",
    observed: true,
    runs: [run({ runID: undefined, runGroup: undefined, pid: 41233, total: 12, done: 7 })],
  });
  state = applyMonitorRunsEvent(state, {
    machine: "M1Ultra",
    observed: true,
    runs: [run({ runID: undefined, runGroup: undefined, pid: 41233, total: 20, done: 3 })],
  });
  const groups = buildRunGroups(state);
  assert.equal(groups.length, 2, "同じ pid でも別の機械なら別の run");
  assert.deepEqual(groups.map((g) => g.total).sort((a, b) => a - b), [12, 20]);
});

test("observed:false の機械の run は数えない・出さない(不明を実行中に混ぜない)", () => {
  let state = applyMonitorRunsEvent(new Map(), { machine: "M1Max", observed: true, runs: [run()] });
  state = applyMonitorRunsEvent(state, { machine: "M1Max", observed: false, runs: [] });
  assert.deepEqual(buildRunGroups(state), []);
});

test("全 run が見積もりを持つときだけ etaSeconds を出す(1本でも欠けたら省く)", () => {
  let state = applyMonitorRunsEvent(new Map(), {
    machine: "A", observed: true, runs: [run({ runID: "a", runGroup: "g", etaSeconds: 100 })],
  });
  state = applyMonitorRunsEvent(state, {
    machine: "B", observed: true, runs: [run({ runID: "b", runGroup: "g", etaSeconds: undefined })],
  });
  assert.equal(buildRunGroups(state)[0].etaSeconds, undefined);

  const complete = applyMonitorRunsEvent(new Map(), {
    machine: "A", observed: true, runs: [run({ runID: "a", runGroup: "g2", etaSeconds: 100 })],
  });
  const both = applyMonitorRunsEvent(complete, {
    machine: "B", observed: true, runs: [run({ runID: "b", runGroup: "g2", etaSeconds: 200 })],
  });
  assert.equal(buildRunGroups(both)[0].etaSeconds, 200, "最大値(直列化された下限)");
});

test("他人の run(mine:false)の issuer は保たれる。自分の run では issuer 無しでよい", () => {
  const state = applyMonitorRunsEvent(new Map(), {
    machine: "M1Max", observed: true,
    runs: [run({ mine: false, issuer: "alice@air" })],
  });
  assert.equal(buildRunGroups(state)[0].issuer, "alice@air");
  assert.equal(buildRunGroups(state)[0].mine, false);
});

test("profile 省略(--dry-run 等)でも group に反映される(project だけになる)", () => {
  const state = applyMonitorRunsEvent(new Map(), {
    observed: true, runs: [run({ profile: undefined })],
  });
  assert.equal(buildRunGroups(state)[0].profile, undefined);
  assert.equal(buildRunGroups(state)[0].project, "ec-mobile");
});

// ---- 秒読み -------------------------------------------------------------------------------

test("liveElapsedSeconds は受信からの経過を足す(負にはならない)", () => {
  const receivedAtMs = 1_000_000;
  assert.equal(liveElapsedSeconds(10, receivedAtMs, receivedAtMs + 5_000), 15);
  assert.equal(liveElapsedSeconds(10, receivedAtMs, receivedAtMs - 5_000), 10, "巻き戻った時計では減らさない");
});

test("liveRemaining: 見積もり無しは undefined、残っている間は remainingSeconds、超過したら overageSeconds", () => {
  const receivedAtMs = 1_000_000;
  assert.equal(liveRemaining(undefined, receivedAtMs, receivedAtMs), undefined);
  const counting = liveRemaining(100, receivedAtMs, receivedAtMs + 40_000);
  assert.equal(counting.remainingSeconds, 60);
  assert.equal(counting.overageSeconds, undefined);
  const overdue = liveRemaining(100, receivedAtMs, receivedAtMs + 130_000);
  assert.equal(overdue.remainingSeconds, 0);
  assert.equal(overdue.overageSeconds, 30);
});

// ---- webview 境界(型検査の効かない postMessage 契約)-----------------------------------------

const wireEvent = {
  kind: "monitorRuns", machine: "M1Max", observed: true,
  runs: [{
    pid: 41233, runID: "run-1", runGroup: "grp-1", issuer: "alice@air", mine: false,
    project: "ec-mobile", profile: "ios-smoke",
    elapsedSeconds: 261, total: 12, done: 7, failed: 2, etaSeconds: null,
    lanes: [{ key: "UDID-1", name: "iPhone 17-01", platform: "ios", scenario: "05_検索",
              scenarioElapsedSeconds: 72 }],
  }],
};

test("isMonitorEvent: monitorRuns の生 NDJSON を受理し、etaSeconds:null を undefined に正規化する", () => {
  const value = structuredClone(wireEvent);
  assert.equal(isMonitorEvent(value), true);
  assert.equal(value.runs[0].etaSeconds, undefined);
});

test("isMonitorEvent: machine 省略(手元)・runID/profile 省略(dry-run 系)・待機中レーン(scenario 省略)も妥当", () => {
  const local = structuredClone(wireEvent);
  delete local.machine;
  assert.equal(isMonitorEvent(local), true);

  const dryRun = structuredClone(wireEvent);
  delete dryRun.runs[0].runID;
  delete dryRun.runs[0].profile;
  assert.equal(isMonitorEvent(dryRun), true);

  const idleLane = structuredClone(wireEvent);
  delete idleLane.runs[0].lanes[0].scenario;
  delete idleLane.runs[0].lanes[0].scenarioElapsedSeconds;
  assert.equal(isMonitorEvent(idleLane), true);
});

test("isMonitorEvent: lanes の型崩れは拒否する。observed:false は runs:[] で妥当", () => {
  const brokenLane = structuredClone(wireEvent);
  brokenLane.runs[0].lanes[0].scenarioElapsedSeconds = "seventy-two";
  assert.equal(isMonitorEvent(brokenLane), false);

  const notObserved = { kind: "monitorRuns", observed: false, runs: [] };
  assert.equal(isMonitorEvent(notObserved), true, "observed:false は runs:[] で妥当");
});

test("toWebviewMessage: monitorRuns はそのまま webview 契約へ渡す(type だけ kind から改名)", () => {
  const value = structuredClone(wireEvent);
  assert.equal(isMonitorEvent(value), true);
  const posted = toWebviewMessage(value);
  assert.equal(posted.type, "monitorRuns");
  assert.equal(posted.machine, "M1Max");
  assert.equal(posted.observed, true);
  assert.deepEqual(posted.runs, value.runs);
});
