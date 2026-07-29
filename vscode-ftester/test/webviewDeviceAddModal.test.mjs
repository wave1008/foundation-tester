// webviewDeviceAddModal.test.mjs
// 「デバイスを追加」モーダル(modals.js)の DOM テスト。実 HTML+実バンドルで動かす方式は
// webviewHoverTip.test.mjs と同じ(harness のコメントはそちら参照)。
//
// 検証対象は「カタログが片側だけ欠けたとき」の見せ方。device-catalog は ok:true のまま
// プラットフォーム単位で部分的に欠ける(avdmanager 不在なら Android の models だけ空になり、
// systemImages は読める)。理由を出さずに空の select だけ見せると、利用者は
// 「モデルを選べない」としか分からず、OK を押しても作成側で同じ理由で落ちる。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
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

/** モーダルは #device-pick-overlay の「+」からしか開かないので、その導線をたどる */
function openDeviceAddModal(window, document) {
  post(window, {
    type: "machineProfileInfo",
    machines: [{ name: "M1", devices: [] }],
    current: "M1",
    error: null,
  });
  document.getElementById("btn-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  document.getElementById("device-pick-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

const AVDMANAGER_MISSING = "avdmanager が見つかりません(...)";

/** Android は systemImages だけ読めてモデル定義が空(= avdmanager 不在)、iOS は正常なカタログ */
function catalogWithoutAndroidModels() {
  return {
    android: {
      available: true,
      error: AVDMANAGER_MISSING,
      models: [],
      systemImages: [{
        abi: "arm64-v8a", apiLevel: 36, package: "system-images;android-36;google_apis_playstore;arm64-v8a",
        tag: "google_apis_playstore", versionName: "Android 16",
      }],
    },
    ios: {
      available: true,
      error: null,
      deviceTypes: [{
        identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        name: "iPhone 17 Pro", productFamily: "iPhone",
      }],
      runtimes: [{
        identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0",
      }],
    },
  };
}

function applyCatalog(window, catalog) {
  post(window, { type: "deviceCatalog", ok: true, catalog, error: null });
}

test("モデルが空のプラットフォームでは理由を出し OK を押させない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());

  // 初期選択は iOS。正常な側では従来どおり選択肢が並び OK が押せる
  assert.equal(document.getElementById("dlg-model").options.length, 1);
  assert.equal(document.getElementById("dlg-error").textContent, "");
  assert.equal(document.getElementById("dlg-ok").disabled, false);

  document.getElementById("dlg-platform-android").checked = true;
  document.getElementById("dlg-platform-android").dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(document.getElementById("dlg-model").options.length, 0, "モデルは空のまま");
  assert.equal(document.getElementById("dlg-os").options.length, 1, "OS バージョンは読めている");
  assert.equal(document.getElementById("dlg-error").textContent, AVDMANAGER_MISSING,
    "CLI 由来の理由文をそのまま見せる");
  assert.equal(document.getElementById("dlg-ok").disabled, true, "作成できない状態で OK を押させない");

  // 戻せば元通り(エラー表示が残らない)
  document.getElementById("dlg-platform-ios").checked = true;
  document.getElementById("dlg-platform-ios").dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(document.getElementById("dlg-error").textContent, "");
  assert.equal(document.getElementById("dlg-ok").disabled, false);
});

test("欠けた側が初期選択でもカタログ受信の時点で理由が出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  // iOS を available:false にすると applyPlatformAvailability が Android 側へ寄せる
  const catalog = catalogWithoutAndroidModels();
  catalog.ios = { available: false, error: "Xcode が見つかりません", deviceTypes: [], runtimes: [] };
  applyCatalog(window, catalog);

  assert.equal(document.getElementById("dlg-platform-android").checked, true);
  assert.equal(document.getElementById("dlg-error").textContent, AVDMANAGER_MISSING);
  assert.equal(document.getElementById("dlg-ok").disabled, true);
});

test("error が無くても両リストが空なら OK は無効(理由は既定文)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  const catalog = catalogWithoutAndroidModels();
  catalog.ios = { available: true, error: null, deviceTypes: [], runtimes: [] };
  applyCatalog(window, catalog);

  assert.equal(document.getElementById("dlg-error").textContent,
    "この OS 種別で選べるモデル/OSバージョンがありません。");
  assert.equal(document.getElementById("dlg-ok").disabled, true);
});
