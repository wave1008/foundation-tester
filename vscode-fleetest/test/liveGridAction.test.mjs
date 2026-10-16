// グリッドビューのライブ操作(gridLiveAction)の host 側。webview 側の挙動は webviewGridLiveControls.test.mjs。
// MonitorLiveController はスタブで作れないので、handleGridAction の配線はソース走査で守る
// (monitorLiveControllerTracePoints.test.mjs と同じ方針)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { isGridLiveAction } from "../src/liveModel";
import { isMonitorFromWebviewMessage } from "../src/monitorWebviewMessages";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

test("isGridLiveAction: ツールバー(開閉を含む)とクリック・修飾キー操作の7種だけを通す", () => {
  assert.equal(isGridLiveAction({ type: "home" }), true);
  assert.equal(isGridLiveAction({ type: "appSwitcher" }), true);
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: false }), true);
  assert.equal(isGridLiveAction({ type: "fold", state: "fold" }), true);
  assert.equal(isGridLiveAction({ type: "fold", state: "half" }), false, "開閉の向きは2つだけ");
  assert.equal(isGridLiveAction({ type: "doubleTapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }), true);
  assert.equal(isGridLiveAction({ type: "tracePoints", points: [{ x: 0, y: 0, t: 0 }], displayWidth: 3, displayHeight: 4 }), true);
  assert.equal(isGridLiveAction({ type: "tapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }), true);
  // ライブ操作には有るがグリッドビューからは撃たないもの(素のドラッグ・長押し・デバイスの切り替え)
  assert.equal(isGridLiveAction({
    type: "dragPoints", fromX: 0, fromY: 0, toX: 1, toY: 1, displayWidth: 3, displayHeight: 4, pressMs: 0, dragMs: 1,
  }), false);
  assert.equal(isGridLiveAction({ type: "pressPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4, holdMs: 600 }), false);
  assert.equal(isGridLiveAction({ type: "selectDevice", id: "ios:A" }), false);
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: "yes" }), false, "中身の検査はライブ操作と同じ");
});

test("isMonitorFromWebviewMessage: gridLiveAction は id・操作・remote を検査する", () => {
  const remote = { machine: "M1Ultra", name: "iPhone", platform: "ios", state: "connected", kind: "virtual" };
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "ios:iPhone", action: { type: "home" } }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "home" }, remote }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "", action: { type: "home" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "refreshSnapshot" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "home" }, remote: { ...remote, machine: "" } }), false);
});

function handleGridActionBody() {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const start = source.indexOf("async handleGridAction(");
  assert.notEqual(start, -1, "handleGridAction が見つからない");
  const end = source.indexOf("private async openDevice(", start);
  assert.notEqual(end, -1);
  return source.slice(start, end);
}

test("handleGridAction: 別のデバイスへはレコーディング中なら切り替えず、openDevice で選び直してから撃つ", () => {
  const body = handleGridActionBody();
  const recording = body.indexOf("isRecordingInProgress()");
  const open = body.indexOf("await this.openDevice(id)");
  assert.ok(recording !== -1 && open !== -1 && recording < open, "記録中の切り替えは断ってから選び直す");
  assert.match(body, /if \(this\.selectedDeviceId !== id\) \{\s*this\.post\(\{ type: "gridActionError"/,
    "選び直せなかったら黙らずにグリッドビューへ言う");
  // 撃つのはライブ操作と同じ経路(座標変換・記録・操作記録を2つ持たない)
  assert.match(body, /this\.handleWebviewMessage\(action\);\s*\}\s*$/);
});

test("handleGridAction: 座標の操作は画面サイズ(lastScreen)が揃うまで観測を待つ", () => {
  const body = handleGridActionBody();
  assert.match(body, /action\.type === "tapPoint" \|\| action\.type === "doubleTapPoint" \|\| action\.type === "tracePoints"\)\s*&& !this\.lastScreen/);
  assert.match(body, /await this\.waitForIdle\(SERVE_REQUEST_TIMEOUT_MS\);\s*if \(!this\.lastScreen\) \{\s*await this\.refreshSnapshot\(\);/);
});
