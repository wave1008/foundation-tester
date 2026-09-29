// webviewLiveFpsSettings.test.mjs
// 設定タブ「デバイス画面」の配信の最大フレームレート(fleetest.liveFps)の往復テスト。
// **型検査の効かない境界**(webview ⇄ 拡張)なので、webview が送る形が拡張側の最終ゲート
// (isMonitorFromWebviewMessage)を通ることまで縛る。実 HTML+実バンドルで動かす方式は
// webviewRemoteHostsSettings.test.mjs と同じ。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";

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

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function fillAndCommit(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

test("fps の欄がデバイス画面セクションにあり、値と既定が往復する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const input = document.getElementById("settings-live-fps");
  assert.ok(input, "fps の入力欄がある");
  const group = input.closest(".settings-group");
  assert.ok(group?.querySelector("#settings-polling-mode"), "ポーリングモードと同じデバイス画面セクションにある");
  assert.equal(input.type, "number");
  assert.equal(input.min, "3");
  assert.equal(input.max, "30");

  post(window, { type: "liveFps", value: 6, default: 12 });
  assert.equal(input.value, "6", "明示設定は値として出す");
  assert.equal(input.placeholder, "12", "既定値はプレースホルダ");

  post(window, { type: "liveFps", value: null, default: 12 });
  assert.equal(input.value, "", "未設定は空欄(既定はプレースホルダ)");
});

test("fps を入れると setLiveFps が送られ、拡張側のゲートを通る", (t) => {
  const posted = [];
  const { window, document } = createWebview((m) => posted.push(m));
  t.after(() => window.close());

  const input = document.getElementById("settings-live-fps");
  for (const [raw, expected] of [["6", 6], ["3", 3], ["30", 30]]) {
    posted.length = 0;
    fillAndCommit(window, input, raw);
    const messages = posted.filter((m) => m?.type === "setLiveFps");
    assert.equal(messages.length, 1, `"${raw}" で1件送る`);
    assert.equal(messages[0].value, expected);
    assert.equal(isMonitorFromWebviewMessage(messages[0]), true, `"${raw}" は拡張側のゲートを通る`);
  }
});

test("fps の空欄・範囲外・小数は null(既定へ戻す)を送り、入力欄を空欄にする", (t) => {
  const posted = [];
  const { window, document } = createWebview((m) => posted.push(m));
  t.after(() => window.close());

  const input = document.getElementById("settings-live-fps");
  post(window, { type: "liveFps", value: 6, default: 12 });
  for (const raw of ["", "2", "31", "abc", "7.5"]) {
    posted.length = 0;
    fillAndCommit(window, input, raw);
    const messages = posted.filter((m) => m?.type === "setLiveFps");
    assert.equal(messages.length, 1, `"${raw}" で1件送る`);
    assert.equal(messages[0].value, null, `"${raw}" は既定へ戻す`);
    assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
    assert.equal(input.value, "", `"${raw}" は空欄にする`);
  }
});

test("拡張側のゲートは範囲外の fps を通さない", () => {
  for (const value of [2, 31, 7.5, "12"]) {
    assert.equal(isMonitorFromWebviewMessage({ type: "setLiveFps", value }), false, `${value} は通さない`);
  }
});
