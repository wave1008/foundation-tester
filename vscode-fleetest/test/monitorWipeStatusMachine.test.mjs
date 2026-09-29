// monitorWipeStatusMachine.test.mjs
// run の自動 Wipe(wipeStatus イベント)の machine を webview まで運ぶこと。機械分担の run では
// 中継(ApiRunMachineFanout.machineStampedWipeStatus)がリモートの子の行に machine を足す。
// 拡張が落とすと webview(deviceTiles.js applyWipeStatus)は machine 省略 = 手元と読み、
// **リモートの Wipe の進行が同名の手元のタイルに出る**。
// fake-deps パターンは monitorRecordingsFinalizing.test.mjs と同じ。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorPanelController } from "../src/monitorPanel";
import { createRunLaneState } from "../src/runLaneModel";

function makePanel() {
  const posts = [];
  const panel = Object.create(MonitorPanelController.prototype);
  Object.assign(panel, {
    laneState: createRunLaneState(),
    wipeInProgress: new Map(),
    laneSectionVisible: false,
    testRunActive: false,
    recordingsFinalizing: false,
    dashboard: { noteRunStarted() {}, noteRunEnded() {} },
    recordings: { refreshSessions: async () => {}, revealRun: async () => {} },
    post: (message) => posts.push(message),
  });
  const wipes = () => posts.filter((m) => m.type === "wipeStatus");
  return { panel, wipes };
}

test("リモートの wipeStatus は machine を付けたまま webview へ送る・手元は省く", () => {
  const { panel, wipes } = makePanel();
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleBusMessage({
    type: "event", runId: 1, event: { kind: "wipeStatus", device: "Pixel 10", machine: "M1Max", phase: "rebooting" },
  });
  panel.handleBusMessage({
    type: "event", runId: 1, event: { kind: "wipeStatus", device: "Pixel 10", phase: "stopping" },
  });
  assert.deepEqual(wipes(), [
    { type: "wipeStatus", name: "Pixel 10", machine: "M1Max", phase: "rebooting" },
    { type: "wipeStatus", name: "Pixel 10", phase: "stopping" },
  ]);
});

test("run が done を送らずに終わったら、残った分を machine ごとに畳む(同名の手元とリモートを混ぜない)", () => {
  const { panel, wipes } = makePanel();
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleBusMessage({
    type: "event", runId: 1, event: { kind: "wipeStatus", device: "Pixel 10", machine: "M1Max", phase: "rebooting" },
  });
  panel.handleBusMessage({
    type: "event", runId: 1, event: { kind: "wipeStatus", device: "Pixel 10", phase: "rebooting" },
  });
  // 手元の分だけ終わる
  panel.handleBusMessage({
    type: "event", runId: 1, event: { kind: "wipeStatus", device: "Pixel 10", phase: "done" },
  });
  panel.handleBusMessage({ type: "runEnded", runId: 1 });
  assert.deepEqual(wipes().slice(3), [
    { type: "wipeStatus", name: "Pixel 10", machine: "M1Max", phase: "done" },
  ], "残っていたのはリモートの分だけ");
});
