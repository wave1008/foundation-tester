// webviewLiveBoundingBoxes.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (harness は webviewDevicesTabVisible.test.mjs と同型)。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象: 「バウンディングボックスを表示」トグル(要素一覧の見出し)。
// 全要素の枠を画像に重ねて出す。枠の座標は hover 枠と同じ frameToDisplayRect(表示px)で、
// 表示サイズが変わるたびに引き直す。トグルの状態は vscode.setState に持つ。

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
  // renderHtml を vscode スタブで実行して実 HTML を得る
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
  const vscodeStub = {
    Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) },
  };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = {
    asWebviewUri: (uri) => `https://localhost${uri.path}`,
    cspSource: "https://localhost",
  };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  // webview バンドル(media/ 出力を経由せず現ソースから直接 bundle する)
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

/** 実 HTML+バンドルを読み込んだ webview 相当の DOM を作り、host への postMessage を捕捉する。
 * スクリプト実行(=webviewBundle の eval)の直後に「ライブ操作」タブへ切り替える(タブ切替は
 * main.js 側の ft-tab-activated 経由で visibility:true を発火させるのに必要)。 */
/** **window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない**
 * (node --test はファイル単位の子プロセスの終了を待つので、1本の閉じ忘れでスイート全体が
 * 止まる。2026-08-17 に実際に起き、npm test が終わらなくなった)。各 test は t.after で閉じる。 */
function createWebview() {
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posts.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const screenshot = window.document.getElementById("live-screenshot");
  // jsdom はレイアウトを持たないため表示サイズを固定で与える(400x800)
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const liveMessages = () => posts.filter((p) => p.type === "live").map((p) => JSON.parse(JSON.stringify(p.message)));
  return { window, document: window.document, posts, screenshot, sendToWebview, liveMessages };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false }) {
  const event = new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
    altKey,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}


const ELEMENTS = [
  { ref: 1, type: "button", label: "ホーム", identifier: "tab_home", value: null,
    frame: { x: 0, y: 760, width: 134, height: 40 } },
  { ref: 2, type: "staticText", label: "情報", identifier: "txt_title", value: null,
    frame: { x: 16, y: 60, width: 370, height: 24 } },
];

const SNAPSHOT = {
  type: "live",
  message: {
    type: "snapshot", platform: "ios",
    screen: { width: 400, height: 800 },
    image: "aW1n",
    elements: ELEMENTS,
  },
};

function boxes(document) {
  return [...document.getElementById("live-boxes-overlay").querySelectorAll("rect")];
}

test("トグルが『要素一覧を更新』の左にある", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const toggle = document.getElementById("live-boxes-toggle");
  assert.ok(toggle, "トグルが存在すること");
  assert.equal(
    toggle.nextElementSibling.id, "live-btn-refresh-snapshot",
    "「要素一覧を更新」のすぐ左に並ぶこと",
  );
  assert.equal(document.getElementById("live-show-boxes").checked, false, "既定は OFF");
});

test("ON で全要素の枠を出し、OFF で消す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 0, "既定(OFF)では枠を出さない");

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  const drawn = boxes(document);
  assert.equal(drawn.length, ELEMENTS.length, "要素の数だけ枠を出すこと");
  // 画面 400x800 を 400x800 で表示しているので 1:1(createWebview の rect スタブ)
  assert.deepEqual(
    drawn.map((r) => [r.getAttribute("x"), r.getAttribute("y"),
                      r.getAttribute("width"), r.getAttribute("height")].join(",")),
    ["0,760,134,40", "16,60,370,24"],
    "枠の位置は要素の frame を表示座標へ写したもの",
  );

  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(boxes(document).length, 0, "OFF で消すこと");
});

test("ON のまま新しい snapshot が来たら枠を引き直す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 2, "前提: 2つ出ている");

  sendToWebview({
    ...SNAPSHOT,
    message: { ...SNAPSHOT.message, elements: [ELEMENTS[0]] },
  });
  assert.equal(boxes(document).length, 1, "新しい木の要素数に追随すること");
});

test("デバイスを切り替えたら枠も捨てる", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 2, "前提: 出ている");

  sendToWebview({ type: "live", message: { type: "clearSnapshot" } });
  assert.equal(boxes(document).length, 0, "前のデバイスの枠を残さないこと");
});
