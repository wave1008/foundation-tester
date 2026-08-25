// webviewRunProfileWorkspace.test.mjs
// 実行プロファイルタブ「リモート制御」のワークスペース欄を実 HTML+実バンドルで確認する
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
  const posted = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return {
    window,
    posted,
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
  assert.equal(input.value, "", "透かしであって値ではない(未指定のまま保存すれば remoteControl は書かれない)");
});

test("プロジェクトが解決できないホストでは透かしを出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ ...PROFILE_INFO, project: "" });

  assert.equal(window.document.getElementById("run-profile-workspace").placeholder, "");
});

// 実行プロファイルのフォーム1件ぶん(値は任意 —— ここで見たいのはボタンの有効化と送信だけ)
const RUN_PROFILE_FIELDS = {
  machine: "M2Ultra",
  app: "sampleapp",
  devices: [],
  fm: true,
  heal: true,
  falsePositiveCheck: false,
  screenLooksLike: true,
  containerInference: true,
  iosInappEngine: true,
  iosFastInput: false,
  homeOnStart: true,
  enableAnimations: false,
  reportDir: "reports",
  defaultTimeout: "",
  updateWebView: true,
  wipeDataOnBloat: true,
  wipeDataThresholdGB: "",
  recoverCpuFallbackToGpu: false,
  locale: "",
  record: false,
  recordFailuresOnly: false,
  recordBitrateKbps: "",
  recordFullResolution: false,
  workspace: "",
};

test("開始/終了スクリプトは入力欄を持たず、雛形を作るボタンだけが出る", (t) => {
  const { window, posted, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(PROFILE_INFO);

  // 名前と置き場所は固定(FTCore.RunHookPlan)。プロファイルに書く項目は増やさない
  assert.equal(window.document.getElementById("run-profile-setup-script"), null);
  assert.equal(window.document.getElementById("run-profile-teardown-script"), null);

  const button = window.document.getElementById("btn-run-profile-hook-scaffold");
  assert.ok(button, "雛形作成ボタンがリモート制御セクションにある");
  assert.match(button.textContent, /雛形/);

  sendToWebview({ type: "runProfileData", profile: "android-1", ok: true, error: null, fields: RUN_PROFILE_FIELDS });
  window.document.getElementById("run-profile-workspace").value = "  ../shared-ws  ";
  posted.length = 0;
  button.click();

  // 入力中の値を trim して送る(保存前に押しても、画面に見えている場所へ作られる)。
  // webview 側のオブジェクトは別 realm なので deepEqual は使えない(参照等価にならない)
  assert.equal(posted.length, 1);
  assert.equal(posted[0].type, "runProfileHookScaffold");
  assert.equal(posted[0].profile, "android-1");
  assert.equal(posted[0].workspace, "../shared-ws");
});
