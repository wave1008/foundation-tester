// 「テスト実行」タブのフリート(タイル領域)の表示トグル(splitter.js)の配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAutoFitToggle.test.mjs と同じ。
// 契約は monitorWebviewMessages.ts の setFleetVisible(webview→host)/ fleetVisible(host→webview)。

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
function createWebview(initialState) {
  const posted = [];
  let state = initialState;
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: (next) => { state = next; },
    getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  // jsdom に無い(splitter.js は握らずに呼ぶ)。無いと pointerdown ハンドラが途中で落ちる。
  window.Element.prototype.setPointerCapture = () => {};
  window.Element.prototype.releasePointerCapture = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted, getState: () => state };
}

const fleetButton = (document) => document.getElementById("btn-fleet-visible");
const isHidden = (document) => document.getElementById("panel-devices").classList.contains("fleet-hidden");
const sentValues = (posted) => posted.filter((m) => m?.type === "setFleetVisible").map((m) => m.value);

test("ボタンは「すべて選択/解除」の左(右端グループの先頭)にあり、既定は表示", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const button = fleetButton(document);
  assert.equal(button.parentElement, document.getElementById("toolbar-tail"));
  assert.equal(button.nextElementSibling, document.getElementById("btn-select-all"));
  assert.equal(button.textContent.trim(), "", "テキストではなくアイコン");
  assert.equal(isHidden(document), false);
  assert.equal(button.getAttribute("aria-pressed"), "true");
  assert.equal(button.getAttribute("aria-label"), "フリートを非表示にする");
});

test("押すと非表示・もう一度押すと表示に戻り、そのたびに host へ保存する", (t) => {
  const { window, document, posted, getState } = createWebview();
  t.after(() => window.close());
  const button = fleetButton(document);

  button.click();
  assert.equal(isHidden(document), true, "タイル領域とスプリッターを隠す");
  assert.equal(button.getAttribute("aria-pressed"), "false");
  assert.equal(button.getAttribute("aria-label"), "フリートを表示する");
  assert.equal(getState().fleetVisible, false);

  button.click();
  assert.equal(isHidden(document), false);
  assert.equal(button.getAttribute("aria-label"), "フリートを非表示にする");
  assert.deepEqual(sentValues(posted), [false, true]);
});

test("host の復元値を反映し、送り返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "fleetVisible", value: false } }));
  assert.equal(isHidden(document), true);
  assert.deepEqual(sentValues(posted), []);
});

test("webview の保存状態が非表示なら再表示時も非表示で始まる", (t) => {
  const { window, document } = createWebview({ fleetVisible: false });
  t.after(() => window.close());
  assert.equal(isHidden(document), true);
});

test("setFleetVisible は host 側の検証を通り、bool 以外は弾く", async () => {
  const { isMonitorFromWebviewMessage } = await import("../src/monitorWebviewMessages");
  assert.equal(isMonitorFromWebviewMessage({ type: "setFleetVisible", value: false }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setFleetVisible", value: "no" }), false);
});
