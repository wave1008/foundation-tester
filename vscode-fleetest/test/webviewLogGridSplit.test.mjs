// 「デバイスモニター」タブ下段の2ペイン化(実行ログビュー #log-pane / グリッドビュー #output-pane)の
// DOM テスト。実 HTML+実バンドルを jsdom で動かす方式は webviewLanePreview.test.mjs と同じ。
// 個々のレーンの選択絞り込み・段組みは webviewLanePreview.test.mjs が持つ。ここは
// ①開閉(見出し行クリック)②スプリッターの出し入れ③1台選択時のログの複製(ミラー)④host との
// 契約(setLogPaneHeight/setLogViewVisible/setGridViewVisible)を見る。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
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
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
  }));
  post(window, { type: "devices", devices });
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

const visibleLogs = (document) =>
  [...document.querySelectorAll("#lanes-grid .lane")].filter((el) => el.style.display !== "none");
const visiblePreviews = (document) =>
  [...document.querySelectorAll("#preview-grid .lane-preview")].filter((el) => el.style.display !== "none");

// ---- ①②: 選択0台/2台の絞り込み(要求どおりの最小確認。詳細は webviewLanePreview.test.mjs) ----

test("選択0台では全レーンのログが #lanes-grid に出て #preview-grid は空", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  assert.equal(visibleLogs(document).length, 3);
  assert.equal(document.getElementById("preview-grid").children.length, 0);
});

test("2台選択でログが2本に絞られ、拡大表示が2枚出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  clickTile(document, 0);
  clickTile(document, 1);
  assert.equal(visibleLogs(document).length, 2);
  assert.equal(visiblePreviews(document).length, 2);
});

// ---- ③: 1台選択でグリッドビューに拡大表示+ログのミラーが出て、appendLaneLine がミラーにも届く ----

test("1台選択でグリッドビューにログの複製が出て、実行ログの新しい行がミラーにも届く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  clickTile(document, 0);

  const pair = document.querySelector("#preview-grid .lane-pair");
  assert.ok(pair, "1台選択でミラーの組が出ること");
  const mirrorBody = pair.querySelector(".lane-log-mirror .lane-body");
  assert.ok(mirrorBody);
  assert.equal(mirrorBody.querySelectorAll(".lane-line").length, 0, "前提: まだ行が無い");

  post(window, { type: "runEvent", action: { type: "line", laneId: "d0", text: "line A" } });
  assert.deepEqual(
    [...mirrorBody.querySelectorAll(".lane-line")].map((el) => el.textContent),
    ["line A"],
    "実行ログビュー本体に届いた行がミラーにも複製されること",
  );
  // 本体側(#lanes-grid)にも同じ行が届いている(ミラーは複製であって移動ではない)
  const mainBody = visibleLogs(document)[0].querySelector(".lane-body");
  assert.deepEqual([...mainBody.querySelectorAll(".lane-line")].map((el) => el.textContent), ["line A"]);

  // 選択していない台(d1)宛ての行はミラーに届かない
  post(window, { type: "runEvent", action: { type: "line", laneId: "d1", text: "line B" } });
  assert.deepEqual(
    [...mirrorBody.querySelectorAll(".lane-line")].map((el) => el.textContent),
    ["line A"],
    "他の台の行はミラーに漏れないこと",
  );
});

// ---- ④: 見出し行クリックで畳める・もう一度で戻る ----

test("実行ログビューの見出し行クリックで畳める(dataset/aria が反転)・もう一度で戻る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const header = document.getElementById("log-view-header");
  const toggle = document.getElementById("log-view-toggle");
  assert.equal(toggle.dataset.expanded, "true", "既定は表示");
  assert.equal(document.getElementById("panel-devices").classList.contains("log-view-hidden"), false);

  header.click();
  assert.equal(toggle.dataset.expanded, "false");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  assert.equal(document.getElementById("panel-devices").classList.contains("log-view-hidden"), true);
  assert.equal(toggle.getAttribute("aria-label"), "実行ログビューを開く");
  assert.deepEqual(posted.filter((m) => m?.type === "setLogViewVisible").map((m) => m.value), [false]);

  header.click();
  assert.equal(toggle.dataset.expanded, "true");
  assert.equal(document.getElementById("panel-devices").classList.contains("log-view-hidden"), false);
  assert.equal(toggle.getAttribute("aria-label"), "実行ログビューを閉じる");
  assert.deepEqual(posted.filter((m) => m?.type === "setLogViewVisible").map((m) => m.value), [false, true]);
});

test("グリッドビューの見出し行クリックで畳める・もう一度で戻る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const header = document.getElementById("grid-view-header");
  const toggle = document.getElementById("grid-view-toggle");
  assert.equal(toggle.dataset.expanded, "true");

  header.click();
  assert.equal(toggle.dataset.expanded, "false");
  assert.equal(document.getElementById("panel-devices").classList.contains("grid-view-hidden"), true);
  assert.equal(toggle.getAttribute("aria-label"), "グリッドビューを開く");
  assert.deepEqual(posted.filter((m) => m?.type === "setGridViewVisible").map((m) => m.value), [false]);

  header.click();
  assert.equal(document.getElementById("panel-devices").classList.contains("grid-view-hidden"), false);
  assert.deepEqual(posted.filter((m) => m?.type === "setGridViewVisible").map((m) => m.value), [false, true]);
});

// 「ライブ更新」のチェックボックス/ラベルは見出し行の中に居るので、押しても見出しの開閉へ波及しない
test("グリッドビュー見出し内の「ライブ更新」トグルは開閉を誤発火しない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const toggle = document.getElementById("grid-view-toggle");
  document.getElementById("chk-show-stream-during-run").click();
  assert.equal(toggle.dataset.expanded, "true", "見出しの開閉が誤って起きていないこと");
});

// ---- ⑤: どちらかが畳まれている間 #splitter-log が隠れる ----
// jsdom は CSS を読まないため、状態(class)の切り替えと、実際に隠す規則がスタイルシートに
// 存在することを別々に確かめる(規約: CSS の契約はスタイルシートのテキスト走査で見る)。

const styleCssSource = readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");

test("style.css: log-view-hidden/grid-view-hidden のどちらでも #splitter-log を隠す規則がある", () => {
  assert.match(
    styleCssSource,
    /#panel-devices\.log-view-hidden #splitter-log[\s\S]*?display:\s*none/,
    "log-view-hidden 側の規則",
  );
  assert.match(
    styleCssSource,
    /#panel-devices\.grid-view-hidden #splitter-log[\s\S]*?display:\s*none/,
    "grid-view-hidden 側の規則",
  );
});

test("どちらかを畳むと devicesPanel に対応するクラスが付く(スプリッターが消える条件)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const panel = document.getElementById("panel-devices");
  assert.equal(panel.classList.contains("log-view-hidden"), false);
  assert.equal(panel.classList.contains("grid-view-hidden"), false);

  document.getElementById("log-view-header").click();
  assert.equal(panel.classList.contains("log-view-hidden"), true);
  document.getElementById("log-view-header").click();
  assert.equal(panel.classList.contains("log-view-hidden"), false);

  document.getElementById("grid-view-header").click();
  assert.equal(panel.classList.contains("grid-view-hidden"), true);
});

// 畳みは CSS(display:none)で行うので、**隠す相手に inline の display が載っていると効かない**。
// jsdom は CSS を読まないのでこの食い違いは見えない —— inline が無いことを直接確かめる
// (かつて #lanes-grid に updateLanesPlaceholder が display:grid を書いていた)。
test("畳む対象(#lanes-grid / #preview-grid)に inline の display を書かない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const lanesGrid = document.getElementById("lanes-grid");
  const previewGrid = document.getElementById("preview-grid");
  const assertNoInlineDisplay = (label) => {
    assert.equal(lanesGrid.style.display, "", `#lanes-grid (${label})`);
    assert.equal(previewGrid.style.display, "", `#preview-grid (${label})`);
  };
  assertNoInlineDisplay("起動直後");
  sendDevices(window, 2);
  assertNoInlineDisplay("デバイス到着後");
  clickTile(document, 0);
  assertNoInlineDisplay("1台選択");
  clickTile(document, 0);
  assertNoInlineDisplay("選択解除");
  document.getElementById("log-view-header").click();
  document.getElementById("grid-view-header").click();
  assertNoInlineDisplay("両方を畳んだ後");
});

test("style.css: 畳んだ側の本体を隠す規則がある", () => {
  assert.match(styleCssSource, /#panel-devices\.log-view-hidden #lanes-grid[\s\S]*?display:\s*none/);
  assert.match(styleCssSource, /#panel-devices\.grid-view-hidden #preview-grid[\s\S]*?display:\s*none/);
});

// 「デバイスを待機しています」(#lanes-waiting)は inline の display で出し入れするので、
// 上の CSS では隠せない。畳みの反映は waitingNote.js の1箇所が解く。
test("グリッドビューを畳むと「デバイスを待機しています」も消える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const waiting = document.getElementById("lanes-waiting");
  // 出る条件はラインビューが畳まれていること(デバイス到着前 = 待機中)
  document.getElementById("line-view-header").click();
  assert.equal(waiting.style.display, "flex", "前提: ラインビューを畳むと下のペインに出る");

  document.getElementById("grid-view-header").click();
  assert.equal(waiting.style.display, "none", "グリッドビューを畳んだら出さない");
  document.getElementById("grid-view-header").click();
  assert.equal(waiting.style.display, "flex", "戻したら再び出る");
});

// ---- host との契約(setLogPaneHeight/setLogViewVisible/setGridViewVisible) ----

test("host の復元値(logViewVisible/gridViewVisible)を反映し、送り返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, { type: "logViewVisible", value: false });
  post(window, { type: "gridViewVisible", value: false });
  assert.equal(document.getElementById("panel-devices").classList.contains("log-view-hidden"), true);
  assert.equal(document.getElementById("panel-devices").classList.contains("grid-view-hidden"), true);
  assert.deepEqual(posted.filter((m) => m?.type === "setLogViewVisible" || m?.type === "setGridViewVisible"), []);
});

test("setLogPaneHeight/setLogViewVisible/setGridViewVisible は host 側の検証を通り、型が違えば弾く", async () => {
  const { isMonitorFromWebviewMessage } = await import("../src/monitorWebviewMessages");
  assert.equal(isMonitorFromWebviewMessage({ type: "setLogPaneHeight", value: 200 }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLogPaneHeight", value: 0 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLogViewVisible", value: true }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLogViewVisible", value: "yes" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setGridViewVisible", value: false }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setGridViewVisible", value: "no" }), false);
});
