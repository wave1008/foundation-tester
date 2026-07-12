// webviewLiveDrag.test.mjs
// ライブ操作タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象(ドラッグ=スワイプ機能の回帰):
// - ライブタブ活性化で visibility / refreshDevices を host へ送る
// - snapshot 未取得のまま frame だけ受信 → refreshSnapshot を一度だけ自動要求(パネル開き直しで
//   ライブタブが復元された直後の「タップ/ドラッグ無反応」の再発防止)
// - snapshot 取得前はポインタ操作を送らない
// - snapshot 取得後: 移動 5px 未満=tapPoint、以上=dragPoints。pointerup は window 側で拾う
//   (setPointerCapture が効かない環境の取りこぼし防止)。範囲外で離したら表示範囲へクランプ

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

/** 実 HTML+バンドルを読み込んだ webview 相当の DOM を作り、host への postMessage を捕捉する。 */
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
  window.eval(webviewBundle);

  const screenshot = window.document.getElementById("live-screenshot");
  // jsdom はレイアウトを持たないため表示サイズを固定で与える(400x800)
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const liveMessages = () => posts.filter((p) => p.type === "live").map((p) => JSON.parse(JSON.stringify(p.message)));
  return { window, posts, screenshot, sendToWebview, liveMessages };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0 }) {
  const event = new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

const SNAPSHOT_MESSAGE = {
  type: "live",
  message: {
    type: "snapshot",
    platform: "ios",
    screen: { width: 400, height: 800 },
    image: "aW1n",
    elements: [],
  },
};
const FRAME_MESSAGE = { type: "live", message: { type: "frame", image: "aW1n" } };

test("ライブタブ活性化で visibility:true と refreshDevices を host へ送る", () => {
  const { window, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();
  const messages = liveMessages();
  assert.ok(messages.some((m) => m.type === "visibility" && m.visible === true));
  assert.ok(messages.some((m) => m.type === "refreshDevices"));
});

test("snapshot 未取得で frame のみ受信: refreshSnapshot を一度だけ自動要求し、ポインタ操作は送らない", () => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();

  sendToWebview(FRAME_MESSAGE);
  sendToWebview(FRAME_MESSAGE);
  const refreshes = liveMessages().filter((m) => m.type === "refreshSnapshot");
  assert.equal(refreshes.length, 1, "frame を複数回受けても自動 refreshSnapshot は一度だけ");

  // lastScreen が無いのでポインタ操作は無反応(押下時点で弾く)
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 300 }));
  const gestures = liveMessages().filter((m) => m.type === "tapPoint" || m.type === "dragPoints");
  assert.equal(gestures.length, 0);
});

test("snapshot 取得後: 5px 以上の移動は dragPoints(window の pointerup で拾う)", () => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();
  sendToWebview(SNAPSHOT_MESSAGE);

  const down = pointerEvent(window, "pointerdown", { x: 100, y: 100 });
  screenshot.dispatchEvent(down);
  assert.equal(down.defaultPrevented, true, "pointerdown でネイティブ画像ドラッグを抑止する");
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 100, y: 300 }));
  // capture が効かない環境を想定し、pointerup は window へ直接投げる
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 300 }));

  const drags = liveMessages().filter((m) => m.type === "dragPoints");
  assert.equal(drags.length, 1);
  const { pressMs, dragMs, ...rest } = drags[0];
  assert.deepEqual(rest, {
    type: "dragPoints",
    fromX: 100, fromY: 100, toX: 100, toY: 300,
    displayWidth: 400, displayHeight: 800,
  });
  assert.equal(typeof pressMs, "number");
  assert.ok(pressMs >= 0);
  assert.equal(typeof dragMs, "number");
  assert.ok(dragMs >= 0);
});

test("snapshot 取得後: 5px 未満の移動は tapPoint になる", () => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 50, y: 60 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 52, y: 61 }));

  const taps = liveMessages().filter((m) => m.type === "tapPoint");
  assert.equal(taps.length, 1);
  assert.deepEqual(taps[0], {
    type: "tapPoint",
    clickX: 52, clickY: 61,
    displayWidth: 400, displayHeight: 800,
  });
  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 0);
});

test("ドラッグ中は軌跡オーバーレイが表示され、離すと消える", () => {
  const { window, screenshot, sendToWebview } = createWebview();
  window.document.getElementById("tab-live").click();
  sendToWebview(SNAPSHOT_MESSAGE);
  const overlay = window.document.getElementById("live-drag-overlay");
  const line = window.document.getElementById("live-drag-line");

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  assert.ok(overlay.classList.contains("visible"), "押下でオーバーレイ表示");
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 250 }));
  assert.equal(line.getAttribute("x2"), "150");
  assert.equal(line.getAttribute("y2"), "250");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 250 }));
  assert.ok(!overlay.classList.contains("visible"), "離すとオーバーレイ非表示");
});

test("500ms 以上ホールドして離すと pressPoint になる", async () => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 80, y: 90 }));
  await new Promise((resolve) => setTimeout(resolve, 550));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 81, y: 90 }));

  const presses = liveMessages().filter((m) => m.type === "pressPoint");
  assert.equal(presses.length, 1);
  assert.equal(presses[0].clickX, 81);
  assert.ok(presses[0].holdMs >= 500);
  assert.equal(liveMessages().filter((m) => m.type === "tapPoint").length, 0);
});

test("画像の外で離したドラッグは表示範囲にクランプされる", () => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  window.document.getElementById("tab-live").click();
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 200, y: 700 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 500, y: 900 }));

  const drags = liveMessages().filter((m) => m.type === "dragPoints");
  assert.equal(drags.length, 1);
  assert.equal(drags[0].toX, 400);
  assert.equal(drags[0].toY, 800);
  assert.equal(typeof drags[0].pressMs, "number");
  assert.ok(drags[0].pressMs >= 0);
  assert.equal(typeof drags[0].dragMs, "number");
  assert.ok(drags[0].dragMs >= 0);
});
