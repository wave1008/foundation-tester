// エラーバナーの寿命の DOM テスト。
//
// **バナーは自動では消えない**。以前は `devices`(監視サイクル = 約2秒ごと)を受けるたびに
// 消していたので、**エラーが読む前に消えた**(実害 2026-08-29)。バナーに出るのはすべて
// 失敗の通知なので、消えてよいのは3つだけ:
//   - 利用者が閉じた(クリック)
//   - 次のバナーで置き換わった
//   - 「モニター再起動」を押した(タイルごと作り直すため)
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。

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
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 監視サイクル1回ぶん(タイル1枚)。 */
function sendDevices(window) {
  post(window, {
    type: "devices",
    devices: [{
      id: "ios:シム1", name: "シム1", platform: "ios", state: "booted", kind: "virtual",
      udid: "UDID-A", recording: false, registered: true,
    }],
  });
}

const banner = (document) => document.getElementById("banner");
const bannerText = (document) => (banner(document).classList.contains("visible") ? banner(document).textContent : "");

function failOp(window, message = "ブリッジを起動できません") {
  post(window, { type: "deviceOpFailed", name: "シム1", message });
}

test("監視サイクル(devices)が来てもエラーバナーは消えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  failOp(window);
  assert.match(bannerText(document), /ブリッジを起動できません/, "前提: 出ている");

  for (let i = 0; i < 5; i += 1) {
    sendDevices(window); // 実機では約2秒ごとに届く
  }
  assert.match(bannerText(document), /ブリッジを起動できません/, "読む前に消えてはいけない");
});

test("クリックで閉じられる(閉じ方をツールチップで示す)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  failOp(window);
  assert.notEqual(banner(document).title, "", "閉じられることを示す");

  banner(document).dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(bannerText(document), "");
});

test("次のバナーで置き換わる(古い失敗を残さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  failOp(window, "1つ目");
  failOp(window, "2つ目");

  assert.match(bannerText(document), /2つ目/);
  assert.doesNotMatch(bannerText(document), /1つ目/);
});

test("「モニター再起動」では消える(タイルごと作り直すため)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  failOp(window);

  document.getElementById("btn-restart").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(bannerText(document), "");
});
