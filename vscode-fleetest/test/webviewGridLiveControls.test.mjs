// グリッドビューのライブ操作(gridLiveControls.js)の DOM テスト。harness は webviewLanePreview.test.mjs と同じ
// (実 HTML + 実バンドルを jsdom で動かす)。
//
// 契約: **1台だけ選択したとき**だけ拡大表示の下にツールバー(ホーム・タスク切替・拡大・縮小・軌跡の表示灯・
// 修飾キーの案内)を出し、操作は gridLiveAction で host へ送る。絵の上のクリックはタップで、
// **絵の上のダブルクリックは選択の切り替えにしない**(切り替えは絵の外側のダブルクリック)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posts.push(m), setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const gridActions = () =>
    posts.filter((p) => p.type === "gridLiveAction").map((p) => JSON.parse(JSON.stringify(p)));
  return { window, document: window.document, gridActions, posts };
}

const send = (window, data) => window.dispatchEvent(new window.MessageEvent("message", { data }));

function sendDevices(window, count, machine, foldable) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
    ...(machine ? { machine } : {}),
    ...(foldable !== undefined ? { foldable: foldable(i) } : {}),
  }));
  send(window, { type: "devices", devices });
}

function layoutTilesForHit(document) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  [...document.querySelectorAll("#grid .tile")].forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
}

function clickTile(document, index) {
  layoutTilesForHit(document);
  const frame = document.querySelectorAll("#grid .tile .frame-wrap")[index];
  frame.dispatchEvent(new document.defaultView.MouseEvent("click", {
    bubbles: true, clientX: index * 110 + 50, clientY: 100,
  }));
}

/** 1台を選び、絵(mjpeg)を出して、拡大表示の絵の矩形を (left=100, top=50, 200×400) に固定する */
function selectOneWithPicture(window, document, index = 0) {
  clickTile(document, index);
  send(window, { type: "frame", device: `d${index}`, jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  assert.ok(media, "拡大表示に絵がある");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });
  return media;
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false, shiftKey = false }) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button, altKey, shiftKey });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

const controlsHost = (document) => document.getElementById("grid-live-controls").parentElement;

test("ツールバーは1台選択のときだけ拡大表示の中に出し、2台に増やすと置き場へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  assert.equal(controlsHost(document).id, "grid-live-parking", "選択0台では出さない");

  clickTile(document, 0);
  assert.ok(controlsHost(document).classList.contains("lane-preview"), "1台なら拡大表示の中");
  const labels = [...document.querySelectorAll("#grid-live-controls button")].filter((b) => !b.hidden).map((b) => b.textContent);
  assert.deepEqual(labels, ["ホーム", "タスク切替", "拡大", "縮小"]);
  assert.equal(document.getElementById("grid-live-trace-indicator").textContent, "軌跡");
  assert.match(document.querySelector("#grid-live-controls .screenshot-hint").textContent, /Option\(⌥\)\+クリック/);

  clickTile(document, 1);
  assert.equal(controlsHost(document).id, "grid-live-parking", "2台では出さない");
});

test("ボタンはその台への gridLiveAction を送る(他の機械のデバイスは remote を運ぶ)", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1, "M1Ultra");
  clickTile(document, 0);
  document.getElementById("grid-live-btn-home").click();
  document.getElementById("grid-live-btn-app-switcher").click();
  document.getElementById("grid-live-btn-zoom-in").click();
  document.getElementById("grid-live-btn-zoom-out").click();
  const actions = gridActions();
  assert.deepEqual(actions.map((m) => m.action), [
    { type: "home" }, { type: "appSwitcher" }, { type: "pinch", zoomIn: true }, { type: "pinch", zoomIn: false },
  ]);
  assert.ok(actions.every((m) => m.id === "d0"));
  assert.deepEqual(actions[0].remote, {
    machine: "M1Ultra", name: "Dev 0", platform: "ios", state: "connected", kind: "virtual", udid: "UDID-0",
  });
});

test("クリックはタップ・Option+クリックはダブルタップを送り、絵の上のダブルクリックは選択を変えない", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  // 2台選択 → 拡大表示のダブルクリックで「このデバイスのみ選択」(もう一度押すと2台へ戻る状態)
  clickTile(document, 1);
  clickTile(document, 0);
  document.querySelectorAll("#preview-grid .lane-preview")[0]
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(controlsHost(document).classList.contains("lane-preview"), true, "1台表示になった");
  send(window, { type: "frame", device: "d0", jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });

  const plainDown = pointerEvent(window, "pointerdown", { x: 150, y: 150 });
  media.dispatchEvent(plainDown);
  assert.equal(plainDown.defaultPrevented, true, "絵の上の押下は操作として受ける(テキスト選択を始めない)");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.deepEqual(gridActions().map((m) => m.action), [
    { type: "tapPoint", clickX: 50, clickY: 100, displayWidth: 200, displayHeight: 400 },
  ]);
  // クリックを続けて押したときに来る dblclick は2回のタップで、選択の切り替えにしない
  media.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(controlsHost(document).classList.contains("lane-preview"), true, "1台表示のまま");

  // 素のドラッグは送らない
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 250 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 250 }));
  assert.equal(gridActions().length, 1, "素のドラッグはデバイスへ送らない");

  const down = pointerEvent(window, "pointerdown", { x: 150, y: 150, altKey: true });
  media.dispatchEvent(down);
  assert.equal(down.defaultPrevented, true);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 151, y: 151, altKey: true }));
  assert.deepEqual(gridActions().map((m) => m.action).slice(1), [
    { type: "doubleTapPoint", clickX: 51, clickY: 101, displayWidth: 200, displayHeight: 400 },
  ]);

  media.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true, altKey: true }));
  assert.equal(controlsHost(document).classList.contains("lane-preview"), true, "1台表示のまま");

  // 絵の外側(デバイス名の段)のダブルクリックは従来どおり選択の切り替え(直前の2台へ戻る)
  document.querySelector("#preview-grid .lane-preview .lane-preview-header")
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(controlsHost(document).id, "grid-live-parking", "2台選択へ戻った");
});

test("Shift+ドラッグは軌跡(tracePoints)を送り、Shift だけのクリックはタップ", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150, shiftKey: true }));
  assert.equal(gridActions().length, 1);
  assert.equal(gridActions()[0].action.type, "tapPoint", "ライブ操作タブと同じ(動かさなければタップ)");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 400, y: 600, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 400, y: 600, shiftKey: true }));
  const message = gridActions()[1];
  assert.equal(message.action.type, "tracePoints");
  assert.equal(message.action.displayWidth, 200);
  assert.deepEqual(message.action.points[0], { x: 10, y: 10, t: 0 });
  const last = message.action.points[message.action.points.length - 1];
  assert.deepEqual([last.x, last.y], [200, 400], "絵の外で離しても絵の範囲に収める");
});

test("失敗はその台のものだけ出し、処理中はボタンを止める", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const error = document.getElementById("grid-live-error");

  send(window, { type: "live", message: { type: "devices", devices: [], selectedId: "other" } });
  send(window, { type: "live", message: { type: "actionError", message: "boom" } });
  assert.equal(error.textContent, "", "ライブ操作が別のデバイスにつないでいる間の失敗は出さない");

  send(window, { type: "live", message: { type: "gridActionError", id: "d0", message: "refused" } });
  assert.equal(error.textContent, "refused");

  send(window, { type: "live", message: { type: "devices", devices: [], selectedId: "d0" } });
  send(window, { type: "live", message: { type: "actionError", message: "tap failed" } });
  assert.equal(error.textContent, "tap failed");
  send(window, { type: "live", message: { type: "actionError", message: "" } });
  assert.equal(error.textContent, "");

  send(window, { type: "live", message: { type: "busy", busy: true } });
  assert.ok([...document.querySelectorAll("#grid-live-controls button")].every((b) => b.disabled));
  send(window, { type: "live", message: { type: "busy", busy: false } });
  assert.ok([...document.querySelectorAll("#grid-live-controls button")].every((b) => !b.disabled));
});

test("グリッドビューの絵のカーソルはライブ操作タブと同じ定義(--touch-cursor)を使う", async () => {
  const fs = await import("node:fs");
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  assert.match(css, /:root \{\s*--touch-cursor: url\('data:image\/svg\+xml/, "定義は1箇所");
  assert.match(css, /#live-screenshot, #live-canvas \{[^}]*cursor: var\(--touch-cursor\);/);
  assert.match(css, /\.lanes-grid\.single-device \.lane-preview-media \{ cursor: var\(--touch-cursor\); \}/);
  assert.equal((css.match(/radialGradient/g) || []).length, 2, "カーソルの SVG を写して2つ持たない(開き・閉じタグの2回だけ)");
});

const visibleFoldLabels = (document, selector) =>
  [...document.querySelectorAll(selector)].filter((b) => b.dataset.fold && !b.hidden).map((b) => b.textContent);
// 開閉ボタンの出し分けは devices サイクルの後の microtask で掛かる(foldButtons.js の登録の注記)
const flushMicrotasks = () => new Promise((resolve) => setTimeout(resolve, 0));

test("開閉ボタンはモニターが折りたためると答えたデバイスだけに出し、押すと fold を送る", async (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  await flushMicrotasks();
  // d0 = 折りたためる / d1 = 折りたためない / d2 = まだ分からない(null)
  sendDevices(window, 3, undefined, (i) => [true, false, null][i]);
  clickTile(document, 0);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), ["折りたたむ", "開く"]);
  document.getElementById("grid-live-btn-fold").click();
  document.getElementById("grid-live-btn-unfold").click();
  assert.deepEqual(gridActions().map((m) => m.action), [
    { type: "fold", state: "fold" }, { type: "fold", state: "unfold" },
  ]);

  clickTile(document, 0);
  clickTile(document, 1);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), [], "折りたためない端末には出さない");
  clickTile(document, 1);
  clickTile(document, 2);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), [], "分からない間は出さない");

  // 後の devices サイクルで折りたためると分かったら出す
  sendDevices(window, 3, undefined, (i) => [true, false, true][i]);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), ["折りたたむ", "開く"]);
});

test("ライブ操作タブの開閉ボタンも選択中のデバイスが折りたためるときだけ出し、live の fold を送る", async (t) => {
  const { window, document, posts } = createWebview();
  t.after(() => window.close());
  await flushMicrotasks();
  sendDevices(window, 2, undefined, (i) => i === 0);
  const liveDevices = [0, 1].map((i) => ({ id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected" }));
  send(window, { type: "live", message: { type: "devices", devices: liveDevices, selectedId: "d1" } });
  assert.deepEqual(visibleFoldLabels(document, "#live-screenshot-actions button"), []);
  send(window, { type: "live", message: { type: "devices", devices: liveDevices, selectedId: "d0" } });
  assert.deepEqual(visibleFoldLabels(document, "#live-screenshot-actions button"), ["折りたたむ", "開く"]);
  document.getElementById("live-btn-unfold").click();
  const live = posts.filter((p) => p.type === "live").map((p) => JSON.parse(JSON.stringify(p.message)));
  assert.deepEqual(live.at(-1), { type: "fold", state: "unfold" });
});
