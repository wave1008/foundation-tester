// webviewAppProfilePhysicalPath.test.mjs
// アプリプロファイルタブ「実機用パッケージパス」(iOS のみ)を実 HTML+実バンドルで確認する
// DOM E2E(jsdom)。ハーネスの作りは test/webviewRunProfileWorkspace.test.mjs と同じ。
//
// 型検査の効かない webview 境界(postMessage の fields)を往復で縛るためのテスト:
// 拡張側(monitorProfileForms.ts)は ios にだけ appPathPhysical を持たせ、android には
// 持たせない —— 送る側と受ける側で欄の集合がズレると保存が黙って落ちる。

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
  profiles: ["ios-1"],
  current: "ios-1",
  filter: "all",
  apps: ["sampleapp"],
  project: "SampleApp",
};

// monitorProfileForms.ts の parseAppProfileForForm が返す形(ios だけ appPathPhysical を持つ)。
const APP_PROFILE_DATA = {
  type: "appProfileData",
  profile: "sampleapp",
  ok: true,
  error: null,
  fields: {
    common: { autoInstall: "true" },
    ios: {
      appName: "サンプル",
      app: "com.example.sampleapp",
      appPath: "build/ios-simulator/Sample.app",
      appPathPhysical: "build/ios-device/Sample.app",
    },
    android: { appName: "サンプル", app: "com.example.sampleapp", appPath: "build/Sample.apk" },
  },
};

function loadedWebview(t) {
  const harness = createWebview();
  t.after(() => harness.window.close());
  harness.sendToWebview(PROFILE_INFO);
  harness.sendToWebview(APP_PROFILE_DATA);
  return harness;
}

test("実機用パッケージパスの欄は iOS だけにあり、読み込んだ値が入る", (t) => {
  const { window } = loadedWebview(t);

  const ios = window.document.getElementById("app-profile-ios-app-path-physical");
  assert.ok(ios, "iOS には実機用パッケージパスの欄がある");
  assert.equal(ios.value, "build/ios-device/Sample.app");
  // Android は同じ APK が実機でも動くので欄を置かない(RunProfile.swift の appPathPhysical と同期)
  assert.equal(window.document.getElementById("app-profile-android-app-path-physical"), null);
});

test("実機用パッケージパスは入力を終えると自動保存され、appProfileSave の ios に載る(android には載らない)", (t) => {
  const { window, posted } = loadedWebview(t);

  const input = window.document.getElementById("app-profile-ios-app-path-physical");
  posted.length = 0;
  input.value = "  build/ios-device/Sample-signed.app  ";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(posted.length, 0, "打鍵ごと(input)には送らない");

  input.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(posted.length, 1);
  assert.equal(posted[0].type, "appProfileSave");
  assert.equal(posted[0].profile, "sampleapp");
  assert.equal(posted[0].fields.ios.appPathPhysical, "build/ios-device/Sample-signed.app");
  assert.equal("appPathPhysical" in posted[0].fields.android, false);

  // 保存中も無効化しない(無効化するとフォーカスが外れ、Tab で次の欄へ移った入力が途切れる)
  assert.equal(input.disabled, false);
});
