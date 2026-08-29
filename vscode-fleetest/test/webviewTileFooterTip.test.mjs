// タイル下の状態行(.tile-state)を**ホバーで全文読める**ことの DOM テスト。
//
// 背景(2026-08-29 の報告): この行は nowrap で、タイル幅に収まらない文言
// (「デバイス異常を検出」など)は見切れる。読む手段が無いと、何の異常か分からないまま
// タイルを眺めることになる。
//
// 守る規律2つ:
//  - 文言があるときは**その文言そのもの**をツールチップにも入れる(見切れても読める)
//  - 説明(bridgeWatch の tip など)があるときは2行目に足す —— 説明だけに差し替えない
//    (差し替えると、見切れている当の1行が読めないまま残る)

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

function sendDevice(window, state) {
  post(window, {
    type: "devices",
    devices: [{
      id: "android:Emu 1", name: "Emu 1", platform: "android", state, kind: "virtual",
      serial: "emulator-5554", recording: false,
    }],
  });
}

function stateBadge(document) {
  return document.querySelector("#grid .tile .tile-state");
}

test("状態行の文言はそのままツールチップにも入る(見切れても読める)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window, "connected");

  post(window, { type: "healthWatch", name: "Emu 1", phase: "unhealthy" });
  const badge = stateBadge(document);
  assert.equal(badge.textContent, "デバイス異常を検出");
  assert.equal(badge.getAttribute("data-hover-tip"), "デバイス異常を検出");
});

test("説明があるときは1行目に文言・2行目に説明(説明だけに差し替えない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window, "booted");

  post(window, { type: "bridgeWatch", name: "Emu 1", phase: "failed" });
  const tip = stateBadge(document).getAttribute("data-hover-tip") ?? "";
  const [first, ...rest] = tip.split("\n");
  assert.equal(first, stateBadge(document).textContent, "1行目は見切れている当の文言");
  assert.ok(rest.join("\n").length > 0, "説明が2行目に無い");
});

test("状態行が空ならツールチップも出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevice(window, "connected");

  const badge = stateBadge(document);
  assert.equal(badge.textContent, "");
  assert.equal(badge.getAttribute("data-hover-tip"), null);
});
