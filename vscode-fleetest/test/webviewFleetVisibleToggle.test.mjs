// 「デバイスモニター」タブのラインビュー(タイル領域)の表示トグル(splitter.js)の配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewSelectAllButton.test.mjs と同じ。
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

const lineViewToggle = (document) => document.getElementById("line-view-toggle");
const isHidden = (document) => document.getElementById("panel-devices").classList.contains("fleet-hidden");
const sentValues = (posted) => posted.filter((m) => m?.type === "setFleetVisible").map((m) => m.value);

// 開閉の口は**見出し行だけ**(ツールバーのトグルは撤去した。ユーザー決定 2026-09-21)——
// 同じ状態を動かす口が2つあると、片方だけ状態表示を直して食い違う
test("開閉の口は見出し行だけ(ツールバーにトグルは無い)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(document.getElementById("btn-fleet-visible"), null, "ツールバーのトグルは撤去");
  const toggle = lineViewToggle(document);
  assert.equal(isHidden(document), false, "既定は表示");
  assert.equal(toggle.dataset.expanded, "true");
  assert.equal(toggle.getAttribute("aria-label"), "ラインビューを閉じる");
});

test("押すと非表示・もう一度押すと表示に戻り、そのたびに host へ保存する", (t) => {
  const { window, document, posted, getState } = createWebview();
  t.after(() => window.close());
  const toggle = lineViewToggle(document);

  toggle.click();
  assert.equal(isHidden(document), true, "タイル領域とスプリッターを隠す");
  assert.equal(toggle.dataset.expanded, "false");
  assert.equal(toggle.getAttribute("aria-label"), "ラインビューを開く");
  assert.equal(getState().fleetVisible, false);

  toggle.click();
  assert.equal(isHidden(document), false);
  assert.equal(toggle.getAttribute("aria-label"), "ラインビューを閉じる");
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

  lineViewToggle(document).click();
  assert.equal(note.style.display, "flex");
  assert.ok(document.getElementById("panel-devices").classList.contains("lanes-waiting-shown"),
    "待機の案内を出している間は、同じ場所の「デバイスを選択して下さい」を隠す合図を付けること");

  lineViewToggle(document).click();
  assert.equal(note.style.display, "none", "ラインビューを戻したら消す");
  assert.ok(!document.getElementById("panel-devices").classList.contains("lanes-waiting-shown"),
    "待機の案内を消したら合図も外すこと");
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
const selectAllOn = (document) => document.getElementById("chk-select-all").checked;
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

// ---- ツールバー右端のグループとセパレーターの初期位置 ----

// ラインビューの開閉も全選択も**見出し行**へ移した(2026-09-21)。ツールバー右端の
// アイコン群は空になったので消してある —— 空の箱を残すと次に何かを足す置き場として復活する
test("ツールバーの右端にアイコン群は無い(開閉も全選択も見出し行へ移した)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(document.getElementById("toolbar-tail"), null);
  assert.equal(document.getElementById("btn-fleet-visible"), null);
  assert.equal(document.getElementById("btn-auto-fit"), null, "自動フィットのボタンは無い");
  const header = document.getElementById("line-view-header");
  assert.equal(document.getElementById("chk-select-all").closest("label").parentElement, header);
});

/** レイアウトのある webview を作る(jsdom は寸法が 0 なので、パネルの高さと offsetParent を与える) */
function createLaidOutWebview(panelHeight, initialState) {
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
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get() { return this.id === "panel-devices" ? panelHeight : 0; },
  });
  Object.defineProperty(window.HTMLElement.prototype, "offsetParent", {
    configurable: true,
    get() { return this.ownerDocument.body; },
  });
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

test("保存値が無いとき、ラインビューの高さは表示エリアの 20%", (t) => {
  const { window, document } = createLaidOutWebview(1000);
  t.after(() => window.close());
  // 表示エリア = パネル 1000 - ツールバー・バナー・セパレーター(jsdom では 0)
  assert.equal(document.getElementById("tile-pane").style.height, "200px");
});

test("保存値があるときは保存値を使う(20% で上書きしない)", (t) => {
  const { window, document } = createLaidOutWebview(1000, { tilePaneHeight: 350 });
  t.after(() => window.close());
  assert.equal(document.getElementById("tile-pane").style.height, "350px");
});

test("読み込み時に表示エリアが測れなくても、測れた最初の描画で 20% を決める", (t) => {
  const { window, document } = createLaidOutWebview(0);
  t.after(() => window.close());
  assert.equal(document.getElementById("tile-pane").style.height, "", "測れない間は書かない");
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get() { return this.id === "panel-devices" ? 800 : 0; },
  });
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(document.getElementById("tile-pane").style.height, "160px");
});

// ラインビューの見出し行(run ボードのヘッダと同じ作り)。**行のどこを押しても開閉**する ——
// 三角だけだと当たり判定が小さい。状態は文字ではなく data-expanded で持ち、向きは CSS が回す。
test("ラインビューの見出し行はどこを押しても開閉する", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const toggle = document.getElementById("line-view-toggle");
  assert.equal(toggle.textContent, "▶");
  assert.equal(toggle.dataset.expanded, "true", "既定は表示");
  assert.equal(document.getElementById("line-view-title").textContent, "デバイス一覧");

  document.getElementById("line-view-title").click();   // 三角ではなくタイトルを押す
  assert.equal(toggle.dataset.expanded, "false");
  assert.equal(isHidden(document), true);
  assert.deepEqual(sentValues(posted), [false], "ツールバーのボタンと同じく host へ永続化させる");

  document.getElementById("line-view-header").click();
  assert.equal(toggle.dataset.expanded, "true");
  assert.deepEqual(sentValues(posted), [false, true]);
});
