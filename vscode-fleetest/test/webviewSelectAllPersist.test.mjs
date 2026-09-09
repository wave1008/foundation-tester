// 「テスト実行」タブ「デバイスを全て選択」トグルの永続化・復元の配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAutoFitToggle.test.mjs と同じ。
//
// 状態は webview の getState ではなく host の workspaceState に持つ(パネルを閉じると
// getState は失われ、次回 VSCode 起動では復元できない)。契約は monitorWebviewMessages.ts の
// setSelectAllDevices(webview→host)/ selectAllDevices(host→webview)。
//
// 検証対象:
// - トグルの値が変わったときだけ host へ送る(同じ値の連続では送らない)
// - 個別選択で全台が揃った/崩れたときも送る(ボタンの見た目が変わる = 記憶すべき状態)
// - host からの復元値がボタン表示に反映され、復元は投げ返さない(往復を作らない)
// - 0枚で ON を復元しても旗は立ち、後から現れた台が選択された状態で並ぶ

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
  const posted = [];
  let state;
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: (next) => { state = next; },
    getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

/** jsdom 側の realm で作られたオブジェクトは deepEqual が prototype 差で落ちるため値だけ見る。 */
function persistedValues(posted) {
  return posted.filter((m) => m?.type === "setSelectAllDevices").map((m) => m.value);
}

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "booted", kind: "virtual",
    udid: `UDID-${i}`, recording: false,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

function restore(window, value) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "selectAllDevices", value } }));
}

function isOn(document) {
  const button = document.getElementById("btn-select-all");
  return button.classList.contains("toggled") && button.getAttribute("aria-pressed") === "true";
}

function selectedTileCount(document) {
  return document.querySelectorAll(".tile.selected").length;
}

function click(window, element) {
  element.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

/** jsdom にはレイアウトが無いのでタイルの当たり矩形を自分で置く(webviewSelectAllButton と同じ形)。 */
function layoutTiles(document) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  stub(document.getElementById("tile-pane"), 0, 0, 1000, 300);
  [...document.querySelectorAll("#grid .tile")].forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
}

/** 画像の中心を押して1台の選択をトグルする(当たり判定は座標で決まる)。 */
function clickImage(window, document, index) {
  const target = document.querySelectorAll("#grid .tile .frame-wrap")[index];
  const [x, y] = [index * 110 + 50, 100];
  target.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, cancelable: true, clientX: x, clientY: y }));
  target.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, cancelable: true, clientX: x, clientY: y }));
}

test("ボタンを押すと ON/OFF が host へ送られる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  posted.length = 0;

  click(window, document.getElementById("btn-select-all"));
  assert.deepEqual(persistedValues(posted), [true]);

  click(window, document.getElementById("btn-select-all"));
  assert.deepEqual(persistedValues(posted), [true, false]);
});

test("値が変わらない操作では送らない(devices サイクルのたびに書かない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  click(window, document.getElementById("btn-select-all"));
  posted.length = 0;

  sendDevices(window, 3);
  sendDevices(window, 4);

  assert.deepEqual(persistedValues(posted), []);
});

test("個別選択で全台が揃ったときも送る(ボタンが解除側へ変わる)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  layoutTiles(document);
  posted.length = 0;

  clickImage(window, document, 0);
  clickImage(window, document, 1);

  assert.equal(isOn(document), true, "全台選択でボタンは解除側になる");
  assert.deepEqual(persistedValues(posted), [true]);
});

test("host からの復元値がボタン表示に反映され、投げ返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  posted.length = 0;

  restore(window, true);
  assert.equal(isOn(document), true);
  assert.equal(selectedTileCount(document), 2);

  restore(window, false);
  assert.equal(isOn(document), false);
  assert.equal(selectedTileCount(document), 0);

  assert.deepEqual(persistedValues(posted), [], "復元をそのまま送り返すと往復になる");
});

test("0枚で ON を復元すると、後から現れた台が選択された状態で並ぶ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  restore(window, true);
  assert.equal(isOn(document), true, "台が1枚も無くても旗は立つ");

  sendDevices(window, 3);
  assert.equal(selectedTileCount(document), 3);
});
