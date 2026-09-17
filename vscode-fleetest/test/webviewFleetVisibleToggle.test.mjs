// 「テスト実行」タブのラインビュー(タイル領域)の表示トグル(splitter.js)の配線テスト。
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
  assert.equal(button.getAttribute("aria-label"), "ラインビューを非表示にする");
});

test("押すと非表示・もう一度押すと表示に戻り、そのたびに host へ保存する", (t) => {
  const { window, document, posted, getState } = createWebview();
  t.after(() => window.close());
  const button = fleetButton(document);

  button.click();
  assert.equal(isHidden(document), true, "タイル領域とスプリッターを隠す");
  assert.equal(button.getAttribute("aria-pressed"), "false");
  assert.equal(button.getAttribute("aria-label"), "ラインビューを表示する");
  assert.equal(getState().fleetVisible, false);

  button.click();
  assert.equal(isHidden(document), false);
  assert.equal(button.getAttribute("aria-label"), "ラインビューを非表示にする");
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

// ラインビューを隠している間は、ラインビューの「デバイスを待機しています」が見えないので下のペインに出す
const waitingInLanes = (document) => document.getElementById("lanes-waiting");

test("待機中にラインビューを隠すと、下のペインに「デバイスを待機しています」を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const note = waitingInLanes(document);
  assert.equal(note.textContent, "デバイスを待機しています");
  assert.equal(document.getElementById("empty").style.display, "flex", "前提: 起動直後は待機中");
  assert.equal(note.style.display, "none", "ラインビューが見えている間は出さない");

  fleetButton(document).click();
  assert.equal(note.style.display, "flex");

  fleetButton(document).click();
  assert.equal(note.style.display, "none", "ラインビューを戻したら消す");
});

test("ラインビュー非表示のまま台が現れたら下のペインの待機表示を消し、再起動で台が消えたら出す", (t) => {
  const { window, document } = createWebview({ fleetVisible: false });
  t.after(() => window.close());
  const note = waitingInLanes(document);
  assert.equal(note.style.display, "flex");

  const post = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  post({ type: "devices", devices: [
    { id: "ios:Sim 1", name: "Sim 1", platform: "ios", state: "connected", kind: "virtual", udid: "U1", recording: false },
  ] });
  assert.equal(note.style.display, "none", "台が現れたら消す");
  assert.equal(document.getElementById("empty").style.display, "none");

  post({ type: "devices", devices: [] });
  assert.equal(note.style.display, "flex", "台が居なくなったら出す");
});

// ラインビューが非表示だとタイルを押して選べないので、初期状態は「すべて選択」
const selectAllOn = (document) => document.getElementById("btn-select-all").getAttribute("aria-pressed") === "true";
const restore = (window, type, value) => window.dispatchEvent(new window.MessageEvent("message", { data: { type, value } }));

test("ラインビュー非表示で開くと、全選択の保存値が OFF でも「すべて選択」から始める(保存値は書き換えない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  restore(window, "fleetVisible", false);
  restore(window, "selectAllDevices", false);
  assert.equal(selectAllOn(document), true);
  assert.deepEqual(posted.filter((m) => m?.type === "setSelectAllDevices"), [], "保存値へ送り返さない");
});

test("ラインビュー表示で開くと、全選択は保存値どおり", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  restore(window, "fleetVisible", true);
  restore(window, "selectAllDevices", false);
  assert.equal(selectAllOn(document), false);
  restore(window, "selectAllDevices", true);
  assert.equal(selectAllOn(document), true);
});
