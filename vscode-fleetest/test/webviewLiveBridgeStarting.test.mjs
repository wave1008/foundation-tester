// webviewLiveBridgeStarting.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// harness は webviewLiveStaleNotice.test.mjs と同型(renderHtml + main.js を実バンドルして
// window.eval で実行する)。
//
// 検証対象: ブリッジの自動起動が進行中(bridgeStarting。契約: ApiLiveCommand.swift 冒頭・
// monitorLiveController.ts の applyBridgeStarting)の間、画面領域に中立の「接続中」表示を出し、
// 起動が終われば(bridgeStarting:false)消えること(接続エラー[#live-conn-overlay]とは別要素)。
// あわせて、同じ状況の操作失敗(actionError の neutral:true)がエラー色にならないこと。

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

function createWebview() {
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const screenshot = window.document.getElementById("live-screenshot");
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  return { window, document: window.document };
}

function sendLive(window, message) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "live", message } }));
}

test("bridgeStarting:true で接続中オーバーレイが出て、conn-overlay(接続エラー)は出ない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const connecting = document.getElementById("live-connecting-overlay");
  const connError = document.getElementById("live-conn-overlay");
  assert.ok(!connecting.classList.contains("visible"), "前提: 最初は出ていない");

  const placeholder = document.getElementById("live-screenshot-placeholder");
  sendLive(window, { type: "bridgeStarting", starting: true });
  assert.ok(connecting.classList.contains("visible"), "starting:true でオーバーレイが出ること");
  assert.ok(placeholder.classList.contains("connecting"),
    "下の「接続されていません」を隠すこと(半透明のオーバーレイ越しに矛盾した2文が見えた)");
  assert.ok(!connError.classList.contains("visible"),
    "接続エラーのオーバーレイは別状態(starting はまだエラーではない)");
});

test("bridgeStarting:false でオーバーレイが消える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const connecting = document.getElementById("live-connecting-overlay");

  sendLive(window, { type: "bridgeStarting", starting: true });
  assert.ok(connecting.classList.contains("visible"));

  sendLive(window, { type: "bridgeStarting", starting: false });
  assert.ok(!connecting.classList.contains("visible"), "starting:false で消えること");
  assert.ok(!document.getElementById("live-screenshot-placeholder").classList.contains("connecting"),
    "starting:false で案内文を戻すこと");
});

test("actionError の neutral:true はエラー色(.neutral 以外の見た目)にしない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const actionError = document.getElementById("live-action-error");
  const actionErrorText = document.getElementById("live-action-error-text");

  sendLive(window, { type: "actionError", message: "device still getting ready", neutral: true });
  assert.ok(actionError.classList.contains("visible"), "文言があれば表示すること");
  assert.ok(actionError.classList.contains("neutral"), "neutral:true は .neutral を付けること");
  assert.equal(actionErrorText.textContent, "device still getting ready");
});

test("actionError の通常の失敗(neutral 省略)は .neutral を付けない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const actionError = document.getElementById("live-action-error");

  sendLive(window, { type: "actionError", message: "some failure" });
  assert.ok(actionError.classList.contains("visible"));
  assert.ok(!actionError.classList.contains("neutral"), "通常の失敗はエラー色のままであること");
});

test("neutral な actionError の後、通常のエラーが来たら .neutral が外れる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const actionError = document.getElementById("live-action-error");

  sendLive(window, { type: "actionError", message: "device still getting ready", neutral: true });
  assert.ok(actionError.classList.contains("neutral"));

  sendLive(window, { type: "actionError", message: "a real failure" });
  assert.ok(!actionError.classList.contains("neutral"), "次のエラーが neutral でなければ外れること");
});
