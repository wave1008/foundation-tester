// 実行ログのペイン(デバイスモニタータブ下段)の右クリック: ログの上では何も出さず(既定の Cut/Copy/Paste も)、
// デバイスを選んだときの拡大表示だけがタイルと同じデバイス操作メニューを開く DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewGpuRestartCarriesMachine.test.mjs と同じ。

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
  const sent = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => sent.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, sent };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 手元の Simulator 1 台(connected)。devices の同期でタイルとレーンが1つずつできる */
function sendDevice(window) {
  post(window, {
    type: "devices",
    devices: [
      { id: "ios:Sim 1", name: "Sim 1", platform: "ios", state: "connected", kind: "virtual",
        udid: "U1", recording: false },
    ],
  });
}

function rightClick(window, el) {
  const event = new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
  el.dispatchEvent(event);
  return event;
}

function selectFirstTile(window, document) {
  document.querySelector("#grid .tile").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }));
}

test("選択があるとき、ログの上の右クリックは既定メニューもデバイスのメニューも出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  selectFirstTile(window, document);
  post(window, { type: "runEvent", action: { type: "line", laneId: "ios:Sim 1", text: "log line" } });
  post(window, { type: "runEvent", action: { type: "line", laneId: "__overall__", text: "overall" } });
  const menu = document.getElementById("device-op-menu");
  const line = [...document.querySelectorAll(".lane-line")].find((l) => l.textContent === "log line");
  const overall = [...document.querySelectorAll(".lane-line")].find((l) => l.textContent === "overall");
  for (const el of [line, overall, document.getElementById("lanes-title"), document.getElementById("lanes-grid")]) {
    assert.equal(rightClick(window, el).defaultPrevented, true, "既定メニューを出さない");
    assert.ok(!menu.classList.contains("visible"), "デバイスのメニューも出さない");
  }
});

test("拡大表示の右クリックは、タイルと同じ「ライブ操作」「停止」のメニューを出す", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  selectFirstTile(window, document);
  const preview = document.querySelector("#preview-grid .lane-preview");
  assert.notEqual(preview.style.display, "none", "選択すると拡大表示になる");

  const event = rightClick(window, preview);
  assert.equal(event.defaultPrevented, true);
  const menu = document.getElementById("device-op-menu");
  assert.ok(menu.classList.contains("visible"), "document の contextmenu で閉じられずに開いたまま");
  assert.notEqual(document.getElementById("device-op-menu-live").style.display, "none");
  const item = document.getElementById("device-op-menu-item");
  assert.equal(item.dataset.op, "down");

  item.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  const op = sent.find((m) => m.type === "deviceOp");
  assert.equal(op.name, "Sim 1");
  assert.equal(op.op, "down");

  rightClick(window, preview);
  document.getElementById("device-op-menu-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(sent.find((m) => m.type === "openLiveForDevice").id, "ios:Sim 1");

  // 開いたメニューはログペインの右クリックで閉じる(document へ伝播させている)
  rightClick(window, preview);
  rightClick(window, document.getElementById("lanes-title"));
  assert.ok(!menu.classList.contains("visible"));
});

const display = (document, id) => document.getElementById(id).style.display;

test("選択が1台も無いとき(すべて解除)、ログの右クリックは「すべて選択」だけのメニューを出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  const menu = document.getElementById("device-op-menu");
  const event = rightClick(window, document.getElementById("lanes-title"));
  assert.equal(event.defaultPrevented, true, "既定メニューは出さない");
  assert.ok(menu.classList.contains("visible"), "document の contextmenu で閉じられずに開いたまま");
  for (const id of ["device-op-menu-item", "device-op-menu-live", "device-op-menu-gpu", "device-op-menu-sep",
    "device-op-menu-select-only", "device-op-menu-deselect-all"]) {
    assert.equal(display(document, id), "none", `${id} は出さない`);
  }
  const selectAll = document.getElementById("device-op-menu-select-all");
  assert.notEqual(selectAll.style.display, "none");
  assert.equal(selectAll.disabled, false);

  selectAll.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 1, "押すと全台が選ばれる");
  assert.ok(!menu.classList.contains("visible"));

  // 選択がある状態では出さない
  rightClick(window, document.getElementById("lanes-title"));
  assert.ok(!menu.classList.contains("visible"));
  // タイルの右クリックでは「すべて解除」が戻る(隠したままにしない)
  rightClick(window, document.querySelector("#grid .tile"));
  assert.ok(menu.classList.contains("visible"));
  assert.notEqual(display(document, "device-op-menu-deselect-all"), "none");
});

// entry 無しで開くメニュー(ラインビューの空きエリア・実行ログビューの「すべて選択」)も、外を押せば閉じる
function press(window, el, type) {
  el.dispatchEvent(new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }));
}

test("ラインビューの空きエリアで開いたメニューは、外を押すと閉じる(項目を選ばなくてよい)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  const menu = document.getElementById("device-op-menu");
  const grid = document.getElementById("grid");
  rightClick(window, grid);
  assert.ok(menu.classList.contains("visible"), "前提: 空きエリアの右クリックで開く");
  assert.equal(document.getElementById("device-op-menu-item").style.display, "none", "前提: デバイスの項目は無い");

  press(window, document.getElementById("lanes-title"), "pointerdown");
  assert.ok(!menu.classList.contains("visible"), "外の pointerdown で閉じる");

  rightClick(window, grid);
  assert.ok(menu.classList.contains("visible"));
  press(window, document.getElementById("lanes-title"), "click");
  assert.ok(!menu.classList.contains("visible"), "外の click でも閉じる");
});

test("メニューの中を押しても閉じず、項目はそのまま実行できる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  const menu = document.getElementById("device-op-menu");
  rightClick(window, document.getElementById("grid"));
  const selectAll = document.getElementById("device-op-menu-select-all");
  press(window, selectAll, "pointerdown");
  assert.ok(menu.classList.contains("visible"), "中の pointerdown では閉じない");
  press(window, selectAll, "click");
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 1, "項目は実行される");
  assert.ok(!menu.classList.contains("visible"));
});

test("実行ログビューの「すべて選択」メニューも、外を押すと閉じる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window);
  const menu = document.getElementById("device-op-menu");
  rightClick(window, document.getElementById("lanes-title"));
  assert.ok(menu.classList.contains("visible"));
  press(window, document.getElementById("grid"), "pointerdown");
  assert.ok(!menu.classList.contains("visible"));
});
