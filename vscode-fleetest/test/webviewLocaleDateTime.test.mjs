// webviewLocaleDateTime.test.mjs
// webview に出る日時が **UI 言語(fleetest.language)に従う** ことの DOM E2E(jsdom)。
// 素の toLocaleString() は VSCode の実行環境ロケール依存で、日本語 UI に "8/18/2026, 4:32:25 PM"
// が混ざる(実害)。逆に 'ja-JP' 固定だと英語 UI に日本語書式が残る。両方向を固定する。
//
// locale は <html lang>(renderHtml が currentLocale() を埋める)→ src/webview/i18n.js。
// バンドル初期化時に1度だけ読むので、eval 前に lang を差し替えて両言語を作る。

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
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" },
    { path: "" },
  );

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

/** lang = 'ja' | 'en'。バンドルを eval する前に差し替えることで UI 言語を切り替える。 */
function createWebview(lang) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.document.documentElement.lang = lang;
  window.eval(webviewBundle);
  const video = window.document.getElementById("recordings-video");
  video.load = () => {};
  video.play = () => Promise.resolve();
  video.pause = () => {};
  return { window, sendToWebview: (data) => window.dispatchEvent(new window.MessageEvent("message", { data })) };
}

// 2026-08-18T07:32:25Z。判定は**書式**なので、実行機のタイムゾーンに依らない形で照合する
// (ja = "YYYY/M/D H:MM:SS"、en-US = "M/D/YYYY, h:MM:SS AM|PM")。
const STARTED_AT = "2026-08-18T07:32:25Z";

const SESSION = {
  project: "sut-ec-mobile",
  runID: "20260818-073225Z-LDIPC95-9d09",
  startedAt: STARTED_AT,
  machine: "LDIPC95",
  devices: [{ platform: "android", device: "Pixel 10-01" }],
  passed: 1,
  failed: 0,
  clipsAttempted: 1,
  clipsFailed: 0,
  encoderFallback: false,
};

function sessionStartedText(window) {
  return window.document.querySelector("#recordings-sessions .recordings-session-started").textContent;
}

test("録画セッション一覧の日時: 日本語 UI は日本語書式", (t) => {
  const { window, sendToWebview } = createWebview("ja");
  t.after(() => window.close());
  sendToWebview({ type: "recordingsSessions", sessions: [SESSION] });

  const text = sessionStartedText(window);
  assert.match(text, /^\d{4}\/\d{1,2}\/\d{1,2} \d{1,2}:\d{2}:\d{2}$/, `ja 書式でない: ${text}`);
});

test("録画セッション一覧の日時: 英語 UI は英語書式", (t) => {
  const { window, sendToWebview } = createWebview("en");
  t.after(() => window.close());
  sendToWebview({ type: "recordingsSessions", sessions: [SESSION] });

  const text = sessionStartedText(window);
  assert.match(text, /^\d{1,2}\/\d{1,2}\/\d{4}, \d{1,2}:\d{2}:\d{2}\s?(AM|PM)$/, `en 書式でない: ${text}`);
});

// プロセスタブの「前回更新」も同じ経路(以前は 'ja-JP' 固定で、英語 UI に日本語書式が残っていた)。
const RESIDENT = {
  type: "residentProcesses",
  ts: Date.parse(STARTED_AT),
  items: [{ label: "monitor", pid: 1234, port: "", zombie: false, command: "fleetest api monitor" }],
};

test("プロセスタブの「前回更新」も UI 言語に従う", (t) => {
  const ja = createWebview("ja");
  t.after(() => ja.window.close());
  ja.sendToWebview(RESIDENT);
  const jaText = ja.window.document.getElementById("resident-updated").textContent;
  assert.match(jaText, /\d{4}\/\d{1,2}\/\d{1,2} \d{1,2}:\d{2}:\d{2}/, `ja 書式でない: ${jaText}`);

  const en = createWebview("en");
  t.after(() => en.window.close());
  en.sendToWebview(RESIDENT);
  const enText = en.window.document.getElementById("resident-updated").textContent;
  assert.match(enText, /\d{1,2}\/\d{1,2}\/\d{4}, \d{1,2}:\d{2}:\d{2}\s?(AM|PM)/, `en 書式でない: ${enText}`);
});
