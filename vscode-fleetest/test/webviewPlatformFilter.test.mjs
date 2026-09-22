// run ボードのヘッダのプラットフォーム表示フィルタ(iOS / Android。既定は両方 ON)の DOM テスト。
// OFF にした側のデバイスは**4つのセクション**(実行中・デバイス一覧・選択したデバイス・実行ログ)
// から同時に消える —— 落とすのは deviceTiles.js の applyDevices の入口1箇所で、4つとも
// そこから作られるため。契約は monitorWebviewMessages.ts の setPlatformFilter / platformFilter。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorWebviewMessages";

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

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** iOS 2台・Android 1台。run ボードのレーンの鍵(udid/serial)と揃えてある。 */
function sendDevices(window) {
  post(window, { type: "devices", devices: [
    { id: "ios:A", name: "iPhone-01", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-1", recording: false, registered: true },
    { id: "ios:B", name: "iPhone-02", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-2", recording: false, registered: true },
    { id: "and:C", name: "Pixel-01", platform: "android", state: "connected", detail: "",
      kind: "virtual", serial: "S-1", recording: false, registered: true },
  ] });
}

const tileNames = (document) => [...document.querySelectorAll("#grid .tile .tile-name")].map((el) => el.textContent);
const boardNames = (document) => [...document.querySelectorAll(".run-board-lane-name")].map((el) => el.textContent);
const logNames = (document) => [...document.querySelectorAll("#lanes-grid .lane")]
  .filter((el) => el.style.display !== "none").map((el) => el.querySelector(".lane-header").textContent);
const previewCount = (document) => [...document.querySelectorAll("#preview-grid .lane-preview")]
  .filter((el) => el.style.display !== "none").length;

test("既定は両方 ON(フィルタを持たない状態と同じ見え方)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(document.getElementById("chk-platform-ios").checked, true);
  assert.equal(document.getElementById("chk-platform-android").checked, true);
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);
});

test("OFF にした側は4つのセクションから同時に消え、戻すとその場で出る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  sendDevices(window);
  document.getElementById("chk-select-all").click();   // 全選択 = 実行ログと拡大表示にも出る
  assert.equal(logNames(document).length, 3, "前提: 実行ログに3台");
  assert.equal(previewCount(document), 3, "前提: 拡大表示に3台");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"], "前提: 実行中のツリーに3台");

  const android = document.getElementById("chk-platform-android");
  android.checked = false;
  android.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "デバイス一覧");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02"], "実行中");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "実行ログ");
  assert.equal(previewCount(document), 2, "選択したデバイス");
  // **次の監視サイクル(約2秒ごと)が来ても隠れたまま** —— 落とすのは applyDevices の入口なので、
  // ここを通さないと隠した台が次のサイクルで戻ってくる
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま(実行ログ)");
  // **次の監視サイクルを待たない** —— 切り替えたその場で戻る(生の一覧を控えてあるため)
  android.checked = true;
  android.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);

  // webview 側の realm で作られたオブジェクトなので、そのまま deepEqual すると prototype 違いで
  // 落ちる(値だけを取り出して比べる)
  assert.deepEqual(
    posted.filter((m) => m?.type === "setPlatformFilter").map((m) => [m.ios, m.android]),
    [[true, false], [true, true]],
  );
});

test("host の復元値はチェックに入り、投げ返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  post(window, { type: "platformFilter", ios: false, android: true });
  assert.equal(document.getElementById("chk-platform-ios").checked, false);
  assert.deepEqual(tileNames(document), ["Pixel-01"]);
  assert.deepEqual(posted.filter((m) => m?.type === "setPlatformFilter"), [], "復元は送り返さない");
});

test("setPlatformFilter は host 側の検証を通り、型が違えば弾く", async () => {
  const { isMonitorFromWebviewMessage } = await import("../src/monitorWebviewMessages");
  assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", ios: true, android: false }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", ios: true }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", ios: "yes", android: false }), false);
});
