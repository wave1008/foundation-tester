// デバイスタブ「auto-fit」トグル(splitter.js)の配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewDevicesTabVisible.test.mjs と同じ。
//
// jsdom にはレイアウトが無い(clientHeight/offsetParent が 0/null)ため、高さの計算自体は
// tileFitModel.test.mjs が受け持つ。ここで見るのは計算に入る前の配線だけ:
// - ボタンがグラフより右・ツールバー右端にあり、テキストを持たない(アイコンのみ)
// - 押下で ON/OFF が入れ替わり、状態が host へ永続化される
// - ON のまま手動でセパレーターをドラッグしたら OFF になる(要件)
// - host からの復元値(tileAutoFit)がボタン表示に反映される

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

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { y, pointerId = 1, button = 0 }) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: 0, clientY: y, button });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

/** jsdom 側の realm で作られたオブジェクトは deepEqual が prototype 差で落ちるため値だけ見る。 */
function autoFitValues(posted) {
  return posted.filter((m) => m?.type === "setTileAutoFit").map((m) => m.value);
}

function autoFitButton(document) {
  return document.getElementById("btn-auto-fit");
}

function isOn(document) {
  const button = autoFitButton(document);
  return button.classList.contains("toggled") && button.getAttribute("aria-pressed") === "true";
}

function click(window, element) {
  element.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

/** セパレーターを dy px ドラッグする。 */
function dragSplitter(window, document, dy) {
  const splitter = document.getElementById("splitter");
  splitter.dispatchEvent(pointerEvent(window, "pointerdown", { y: 100 }));
  splitter.dispatchEvent(pointerEvent(window, "pointermove", { y: 100 + dy }));
  splitter.dispatchEvent(pointerEvent(window, "pointerup", { y: 100 + dy }));
}

test("ボタンはホストグラフより後ろ・ツールバー最後の要素で、テキストを持たない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const toolbar = document.getElementById("toolbar");
  const button = autoFitButton(document);
  assert.ok(button, "#btn-auto-fit がツールバーに存在する");
  assert.equal(button.parentElement, toolbar);
  assert.equal(toolbar.lastElementChild, button, "グラフより右(=最後)に置く");
  assert.ok(
    button.compareDocumentPosition(document.getElementById("host-metrics")) &
      window.Node.DOCUMENT_POSITION_PRECEDING,
    "host-metrics より後ろ",
  );
  assert.equal(button.textContent.trim(), "", "テキストではなくアイコン(インライン SVG)");
  assert.equal(button.querySelectorAll("svg").length, 1);
  assert.ok(button.getAttribute("title"), "アイコンのみなので title で意味を伝える");
});

test("初期状態は OFF(手動でセパレーターを動かせる従来動作)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(isOn(document), false);
  assert.equal(autoFitButton(document).getAttribute("aria-pressed"), "false");
});

test("押すと ON になり host へ永続化される", (t) => {
  const { window, document, posted, getState } = createWebview();
  t.after(() => window.close());
  posted.length = 0;

  click(window, autoFitButton(document));

  assert.equal(isOn(document), true);
  assert.deepEqual(autoFitValues(posted), [true]);
  assert.equal(getState().tileAutoFit, true, "パネル再表示用に webview 側にも残す");
});

test("もう一度押すと OFF になり、その時点の高さも手動位置として保存される", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  click(window, autoFitButton(document));
  posted.length = 0;

  click(window, autoFitButton(document));

  assert.equal(isOn(document), false);
  assert.deepEqual(autoFitValues(posted), [false]);
  assert.equal(
    posted.filter((m) => m?.type === "setTilePaneHeight").length,
    1,
    "OFF 直後の高さを残さないと、次回復元で auto-fit 前の位置へ戻る",
  );
});

test("ON のまま手動でセパレーターをドラッグすると OFF になる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  click(window, autoFitButton(document));
  posted.length = 0;

  dragSplitter(window, document, 40);

  assert.equal(isOn(document), false, "手動調整が自動再計算で戻されないよう解除する");
  assert.deepEqual(autoFitValues(posted), [false]);
});

test("動かさなかったドラッグ(0px)では ON のまま", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  click(window, autoFitButton(document));
  posted.length = 0;

  dragSplitter(window, document, 0);

  assert.equal(isOn(document), true);
  assert.deepEqual(autoFitValues(posted), []);
});

test("解除の postMessage はドラッグ1回につき1度だけ", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  click(window, autoFitButton(document));
  posted.length = 0;

  const splitter = document.getElementById("splitter");
  splitter.dispatchEvent(pointerEvent(window, "pointerdown", { y: 100 }));
  for (const y of [110, 120, 130, 140]) {
    splitter.dispatchEvent(pointerEvent(window, "pointermove", { y }));
  }
  splitter.dispatchEvent(pointerEvent(window, "pointerup", { y: 140 }));

  assert.deepEqual(autoFitValues(posted), [false]);
});

test("host からの復元値(tileAutoFit)がボタン表示に反映される", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "tileAutoFit", value: true } }));
  assert.equal(isOn(document), true);

  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "tileAutoFit", value: false } }));
  assert.equal(isOn(document), false);
});

test("webview の保存状態が ON ならパネル再表示時も ON で始まる", (t) => {
  const { window, document } = createWebview({ tileAutoFit: true });
  t.after(() => window.close());
  assert.equal(isOn(document), true);
});
