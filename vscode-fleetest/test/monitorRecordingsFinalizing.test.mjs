// monitorRecordingsFinalizing.test.mjs
// 「テスト実行」ボタン右の「録画を編集中」表示(MonitorPanelController の setRecordingsFinalizing)の出し入れ。
// 出すのは recordingFinalizing イベント(CLI: テストが全部終わり、録画の切り出しだけが残った)から、
// run 終了後の録画タブへの自動表示(revealRun)が片付くまで。消し忘れると次の run まで残り、
// 早く消すと切り出し待ちの間に何も出ない。
// MonitorPanelController は vscode に依存するコンストラクタを通さず、handleBusMessage が触る欄だけ差し込む
// (fake-deps パターンは monitorProfilesProjectList.test.mjs と同じ)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorPanelController } from "../src/monitorPanel";
import { createRunLaneState } from "../src/runLaneModel";

function makePanel() {
  const posts = [];
  const reveals = [];
  let finishReveal;
  const panel = Object.create(MonitorPanelController.prototype);
  Object.assign(panel, {
    laneState: createRunLaneState(),
    wipeInProgress: new Set(),
    laneSectionVisible: false,
    testRunActive: false,
    recordingsFinalizing: false,
    dashboard: { noteRunStarted() {}, noteRunEnded() {} },
    recordings: {
      refreshSessions: async () => {},
      revealRun: (project, runID) => {
        reveals.push({ project, runID });
        return new Promise((resolve) => {
          finishReveal = () => {
            posts.push({ type: "recordingsSession", reveal: true });
            resolve();
          };
        });
      },
    },
    post: (message) => posts.push(message),
  });
  const finalizingStates = () => posts.filter((m) => m.type === "recordingsFinalizing").map((m) => m.active);
  return { panel, posts, reveals, finalizingStates, finishReveal: () => finishReveal() };
}

test("recordingFinalizing で出し、録画タブへの自動表示を送ってから消す", async () => {
  const { panel, posts, reveals, finalizingStates, finishReveal } = makePanel();
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleBusMessage({ type: "event", runId: 1, event: { kind: "recordingFinalizing" } });
  assert.deepEqual(finalizingStates(), [false, true]);

  panel.handleBusMessage({ type: "runEnded", runId: 1, resultRun: { project: "P", runID: "20260911-000000" } });
  assert.deepEqual(reveals, [{ project: "P", runID: "20260911-000000" }]);
  assert.deepEqual(finalizingStates(), [false, true], "録画を読み込むまでは出したまま");

  finishReveal();
  await new Promise((resolve) => setImmediate(resolve));
  const revealAt = posts.findIndex((m) => m.type === "recordingsSession");
  const hiddenAt = posts.findLastIndex((m) => m.type === "recordingsFinalizing");
  assert.equal(posts[hiddenAt].active, false);
  assert.ok(revealAt < hiddenAt, "録画タブへの切り替え(reveal)を送ってから消す");
});

test("結果の run が無い終わり方(キャンセル・異常終了・dry-run)でもその場で消す", () => {
  const { panel, finalizingStates } = makePanel();
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleBusMessage({ type: "event", runId: 1, event: { kind: "recordingFinalizing" } });
  panel.handleBusMessage({ type: "runEnded", runId: 1 });
  assert.deepEqual(finalizingStates(), [false, true, false]);
});

test("recordingFinalizing が来ない run(録画しない)では一度も出さない", () => {
  const { panel, finalizingStates } = makePanel();
  panel.handleBusMessage({ type: "runStarted", runId: 1, isDryRun: false, liveFollow: false });
  panel.handleBusMessage({ type: "event", runId: 1, event: { kind: "runFinished", passed: 1, failed: 0 } });
  panel.handleBusMessage({ type: "runEnded", runId: 1 });
  assert.equal(finalizingStates().includes(true), false);
});
