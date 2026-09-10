// monitorRunButtonState.test.mjs
// 「テスト実行」ボタンの実行中表示(= 「テストを中断」)が、run が始まらなかったときにも戻ること。
// 押下で立てた testRunActive は runEnded でしか戻らない作りだったため、fleetest.runAllTests が
// run を始めずに抜ける経路(対象0件・プロジェクト未解決・互換チェック失敗・開始前の中断)で
// 「テストを中断」のまま固まり、「モニター再起動」でも戻らなかった。
// MonitorPanelController は vscode に依存するコンストラクタを通さず、使う欄だけ差し込む
// (fake-deps パターンは monitorRecordingsFinalizing.test.mjs と同じ)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorPanelController } from "../src/monitorPanel";
import { createRunLaneState } from "../src/runLaneModel";

function makePanel(runAllTests) {
  const posts = [];
  const panel = Object.create(MonitorPanelController.prototype);
  Object.assign(panel, {
    laneState: createRunLaneState(),
    wipeInProgress: new Set(),
    laneSectionVisible: false,
    testRunActive: false,
    busRunActive: false,
    pendingRunStart: false,
    runStartAborted: false,
    recordingsFinalizing: false,
    dashboard: { noteRunStarted() {}, noteRunEnded() {} },
    recordings: { refreshSessions: async () => {}, revealRun: async () => {} },
    deviceOps: { bulkUpWithRestarts() {}, whenLifecycleQueueIdle: async () => {}, cancelBulkUp() {} },
    deviceStream: { restartAllStreams() {} },
    processManager: { restartAll() {} },
    post: (message) => posts.push(message),
  });
  panel.runAllTests = () => runAllTests(panel);
  const runActiveStates = () => posts.filter((m) => m.type === "testRunActive").map((m) => m.active);
  return { panel, runActiveStates };
}

test("run を始めずにコマンドが戻ったら実行中表示を戻す", async () => {
  const { panel, runActiveStates } = makePanel(async () => {});
  await panel.startTestRunAfterDevicesUp();
  assert.deepEqual(runActiveStates(), [true, false]);
});

test("コマンドが失敗しても実行中表示を戻す", async () => {
  const { panel, runActiveStates } = makePanel(async () => {
    throw new Error("command failed");
  });
  await assert.rejects(panel.startTestRunAfterDevicesUp());
  assert.deepEqual(runActiveStates(), [true, false]);
});

test("run が走って終わったときも最後は実行中表示が戻っている(false の再送は冪等)", async () => {
  const { panel, runActiveStates } = makePanel(async (p) => {
    p.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
    p.handleBusMessage({ type: "runEnded", runId: 1 });
  });
  await panel.startTestRunAfterDevicesUp();
  assert.deepEqual(runActiveStates(), [true, true, false, false]);
  assert.equal(panel.testRunActive, false);
});

test("コマンドが戻った時点で別の run(Test Explorer から)が走っていれば戻さない", async () => {
  const { panel } = makePanel(async (p) => {
    p.handleBusMessage({ type: "runStarted", runId: 2, isDryRun: false, liveFollow: false });
  });
  await panel.startTestRunAfterDevicesUp();
  assert.equal(panel.testRunActive, true);
});

test("モニター再起動: 固まった実行中表示を実体(run も起動待ちも無い)に合わせて戻す", () => {
  const { panel, runActiveStates } = makePanel(async () => {});
  panel.testRunActive = true;
  panel.handleWebviewMessage({ type: "restartMonitor" });
  assert.deepEqual(runActiveStates(), [false]);
});

test("モニター再起動: run が走っている間は実行中のまま", () => {
  const { panel, runActiveStates } = makePanel(async () => {});
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleWebviewMessage({ type: "restartMonitor" });
  assert.deepEqual(runActiveStates(), [true, true]);
});
