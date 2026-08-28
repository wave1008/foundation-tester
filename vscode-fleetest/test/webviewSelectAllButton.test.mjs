// ツールバーの全選択トグル(#btn-select-all)の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。
//
// 選択状態は webview 内部の Set にしか無いので、外から見える .tile.selected で判定する
// (拡張ホストへは送っていない = 往復テストでは捕まえられない)。

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
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "booted", kind: "virtual",
    udid: `UDID-${i}`, recording: false,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

const button = (document) => document.getElementById("btn-select-all");
/** 自前ツールチップ(hoverTip.js)が読む属性。ネイティブ title は使わない。 */
const tip = (_document, el) => el.getAttribute("data-hover-tip") || "";
const selectedCount = (document) => document.querySelectorAll("#grid .tile.selected").length;

function click(document, el) {
  el.dispatchEvent(new document.defaultView.MouseEvent("click", { bubbles: true }));
}

test("高さ自動調整ボタンのすぐ左に置く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const el = button(document);
  assert.equal(el.parentElement, document.getElementById("toolbar"));
  assert.equal(el.nextElementSibling, document.getElementById("btn-auto-fit"));
  assert.equal(el.textContent.trim(), "", "テキストではなくアイコン(インライン SVG)");
  assert.equal(el.querySelectorAll("svg").length, 1);
});

test("台数が0のときは押せない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(button(document).disabled, true);
});

test("押すと全デバイスが選択され、もう一度押すと全解除される", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 4);
  assert.equal(button(document).disabled, false);
  assert.equal(selectedCount(document), 0);

  click(document, button(document));
  assert.equal(selectedCount(document), 4, "全選択");
  assert.equal(button(document).getAttribute("aria-pressed"), "true");

  click(document, button(document));
  assert.equal(selectedCount(document), 0, "もう一度押すと全解除");
  assert.equal(button(document).getAttribute("aria-pressed"), "false");
});

test("説明は次に何が起きるかを示す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  const before = tip(document, button(document));
  assert.ok(before.length > 0, "初期表示から説明が入っている");
  click(document, button(document));
  assert.notEqual(tip(document, button(document)), before, "全選択後は解除側の説明になる");
  assert.equal(button(document).getAttribute("aria-label"), tip(document, button(document)));
});

test("右端の2つはネイティブ title ではなく自前ツールチップで説明を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  for (const id of ["btn-select-all", "btn-auto-fit"]) {
    const el = document.getElementById(id);
    assert.ok(tip(document, el).length > 0, `${id}: 説明が入っている`);
    // title が残っていると 0.2 秒でこちらが出た約1秒後にネイティブも出て二重に見える
    assert.equal(el.title, "", `${id}: ネイティブ title は残さない`);
  }
});

test("デバイスが増えたら全選択の続きではなく「全選択」に戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  click(document, button(document));
  assert.equal(button(document).getAttribute("aria-pressed"), "true");

  sendDevices(window, 3); // 3台目が起動 = 全部は選ばれていない
  assert.equal(button(document).getAttribute("aria-pressed"), "false", "押せば残り1台も選べる");
  click(document, button(document));
  assert.equal(selectedCount(document), 3);
});

test("全部消えたら押せない状態に戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  click(document, button(document));
  sendDevices(window, 0);
  assert.equal(button(document).disabled, true);
  assert.equal(button(document).getAttribute("aria-pressed"), "false");
});
