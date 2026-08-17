// webviewRunProfileWorkspace.test.mjs
// 実行プロファイルタブ「ファイル同期」のワークスペース欄を実 HTML+実バンドルで確認する
// DOM E2E(jsdom)。ハーネスの作り(renderHtml を vscode スタブ付きで bundle → main.js を
// window.eval)は test/webviewRecordingsTab.test.mjs と同じ。
//
// 既定値の透かしは Sources/FTCore/RunProfile.swift の ProfileResolver.resolveWorkspaceRoot
// (未指定なら <プロジェクトルート>/workspace)と同期する契約。相対パスはリポジトリルート基準
// なので "TestProjects/<project>/workspace" はそのまま入力しても既定と同じ場所を指す。

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

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return {
    window,
    sendToWebview: (data) => window.dispatchEvent(new window.MessageEvent("message", { data })),
  };
}

const PROFILE_INFO = {
  type: "profileInfo",
  profiles: ["android-1"],
  current: "android-1",
  filter: "all",
  apps: ["sut-ec-mobile"],
  project: "sut-ec-mobile",
};

test("ワークスペース欄に既定値が透かしで出る", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(PROFILE_INFO);

  const input = window.document.getElementById("run-profile-workspace");
  assert.equal(input.placeholder, "TestProjects/sut-ec-mobile/workspace");
  assert.equal(input.value, "", "透かしであって値ではない(未指定のまま保存すれば fileSync は書かれない)");
});

test("プロジェクトが解決できないホストでは透かしを出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ ...PROFILE_INFO, project: "" });

  assert.equal(window.document.getElementById("run-profile-workspace").placeholder, "");
});
