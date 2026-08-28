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

const tiles = (document) => [...document.querySelectorAll("#grid .tile")];

/** Cmd(または Ctrl)+A。戻り値は既定動作を止めたか(webview 既定の「テキスト全選択」の横取り)。 */
function pressSelectAllKey(document, target, { meta = true, ctrl = false, shift = false } = {}) {
  const event = new document.defaultView.KeyboardEvent("keydown", {
    key: "a", metaKey: meta, ctrlKey: ctrl, shiftKey: shift, bubbles: true, cancelable: true,
  });
  target.dispatchEvent(event);
  return event.defaultPrevented;
}

test("高さ自動調整ボタンと1つのグループに入り、そのすぐ左に置く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const el = button(document);
  // どちらもタイルの見え方を操るので同じ枠に入れる(ツールバーの他のボタンとは gap で切る)
  const group = document.getElementById("toolbar-tail");
  assert.equal(el.parentElement, group);
  assert.equal(group.parentElement, document.getElementById("toolbar"));
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

// ---- Cmd/Ctrl+A(フリートを触っている間だけ) ----
// 「触っている」= 最後に押した場所がタイルペインの中、またはフォーカスがその中にある。
// **フォーカスだけを条件にしない** —— タイルは div(tabindex=-1)で、webview では押しても
// activeElement が body のままになることがある(実害 2026-08-28: フォーカス条件だけの版は
// 実機の webview で一度も発火しなかった)。

/** ペイン内/外を押す(pointerdown は capture で拾うので target だけ合っていればよい)。 */
function pointerDown(document, el) {
  el.dispatchEvent(new document.defaultView.MouseEvent("pointerdown", { bubbles: true }));
}

const guarded = (document) => document.documentElement.classList.contains("select-all-guard");

test("タイルを押したあと Cmd+A で全選択、もう一度で全解除", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  const tile = tiles(document)[0];
  pointerDown(document, tile);

  assert.equal(pressSelectAllKey(document, tile), true, "既定の「テキスト全選択」は止める");
  assert.equal(selectedCount(document), 3);
  assert.equal(button(document).getAttribute("aria-pressed"), "true", "ボタンの表示も解除側になる");

  pressSelectAllKey(document, tile);
  assert.equal(selectedCount(document), 0);
});

test("フォーカスがタイルにある経路でも効く(押した場所と両輪)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  const tile = tiles(document)[0];
  tile.focus();

  pressSelectAllKey(document, tile);
  assert.equal(selectedCount(document), 2);
});

test("Ctrl+A でも同じ(Windows/Linux のキーバインド)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  pointerDown(document, tiles(document)[0]);

  pressSelectAllKey(document, document.body, { meta: false, ctrl: true });
  assert.equal(selectedCount(document), 2);
});

test("キーはどこに届いても効く(タイルにフォーカスが入らない webview の経路)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  pointerDown(document, tiles(document)[0]);
  assert.notEqual(document.activeElement, tiles(document)[0], "前提: フォーカスは入っていない");

  // keydown は body に届く。document の capture で拾うので、経路に依らず効く
  pressSelectAllKey(document, document.body);
  assert.equal(selectedCount(document), 3);
});

test("フリートの外を押したあとは横取りしない(既定の全選択が要る場所を潰さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  pointerDown(document, tiles(document)[0]);
  pointerDown(document, button(document));

  assert.equal(pressSelectAllKey(document, document.body), false, "既定動作を止めない");
  assert.equal(selectedCount(document), 0);
});

test("修飾なし・Shift 付きの A は無視する(単なる文字入力を奪わない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  const tile = tiles(document)[0];
  pointerDown(document, tile);

  assert.equal(pressSelectAllKey(document, tile, { meta: false }), false, "修飾なし");
  assert.equal(pressSelectAllKey(document, tile, { shift: true }), false, "Cmd+Shift+A");
  assert.equal(selectedCount(document), 0);
});

// ---- テキスト全選択の抑止 ----
// **preventDefault では止まらない**(実測 2026-08-28)。VSCode(Electron)の「すべて選択」は
// ネイティブメニュー経由でも走り、届く時刻も keydown とずれるので removeAllRanges も
// 間に合わない。選択できるものを無くす(user-select:none)のが唯一効く。

test("フリートを触っている間はページ全体を選択不可にする(押した瞬間から)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  assert.equal(guarded(document), false, "既定では掛けない");

  pointerDown(document, tiles(document)[0]);
  assert.equal(guarded(document), true, "キーを待たずに掛ける = いつ届いても反転しない");
});

test("フリートの外を押したら選択可に戻す(ログのコピーを潰さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  pointerDown(document, tiles(document)[0]);
  assert.equal(guarded(document), true, "前提");

  // ドラッグ選択は pointerdown が先に来るので、その時点で外れている
  pointerDown(document, document.getElementById("lanes-grid"));
  assert.equal(guarded(document), false);
});

test("フリートの外へフォーカスが移ったら選択可に戻す(タブ移動・入力欄)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  pointerDown(document, tiles(document)[0]);

  button(document).focus();
  assert.equal(guarded(document), false);
});

test("既に立っている選択は畳む(ペインを押す前に作ったもの)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  pointerDown(document, tiles(document)[0]);

  let cleared = 0;
  window.getSelection = () => ({ removeAllRanges: () => { cleared += 1; } });
  pressSelectAllKey(document, document.body);

  assert.equal(cleared, 1);
});
