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

/** モーダルは #device-pick-overlay のグループ見出しの「+」からしか開かないので、その導線をたどる */
function openDeviceAddModal(window, document, platform = "ios") {
  post(window, {
    type: "machineProfileInfo",
    machines: [{ name: "M1", devices: [] }],
    current: "M1",
    error: null,
  });
  document.getElementById("btn-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  document.getElementById(`device-pick-${platform}-add-new`)
    .dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function switchTo(window, document, platform) {
  const radio = document.getElementById(`dlg-platform-${platform}`);
  radio.checked = true;
  radio.dispatchEvent(new window.Event("change", { bubbles: true }));
}

const AVDMANAGER_MISSING = "avdmanager が見つかりません(...)";

/** Android は systemImages だけ読めてモデル定義が空(= avdmanager 不在)、iOS は正常なカタログ */
function catalogWithoutAndroidModels() {
  return {
    android: {
      available: true,
      error: AVDMANAGER_MISSING,
      errorCode: "avdmanager-missing",
      models: [],
      systemImages: [
        {
          abi: "arm64-v8a", apiLevel: 36, package: "system-images;android-36;google_apis_playstore;arm64-v8a",
          tag: "google_apis_playstore", versionName: "Android 16",
        },
        {
          abi: "arm64-v8a", apiLevel: 36, package: "system-images;android-36;google_apis;arm64-v8a",
          tag: "google_apis", versionName: "Android 16",
        },
        {
          abi: "arm64-v8a", apiLevel: 35, package: "system-images;android-35;google_apis;arm64-v8a",
          tag: "google_apis", versionName: "Android 15",
        },
      ],
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

/** avdmanager もある正常な Android カタログ(モデルまで揃っている) */
function readyCatalog() {
  const catalog = catalogWithoutAndroidModels();
  catalog.android.error = null;
  catalog.android.errorCode = null;
  catalog.android.models = [{ id: "pixel_9", name: "Pixel 9" }];
  return catalog;
}

function optionLabels(document, id) {
  return [...document.getElementById(id).options].map((o) => o.textContent);
}

test("サービスは Android のときだけ出て、既定は Google APIs", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, readyCatalog());

  const row = document.getElementById("dlg-service-row");
  assert.equal(row.hidden, true, "iOS では出さない");

  switchTo(window, document, "android");
  assert.equal(row.hidden, false);
  assert.deepEqual(optionLabels(document, "dlg-service"), ["Google Play Store", "Google APIs"]);
  assert.equal(document.getElementById("dlg-service").value, "google_apis", "既定は Google APIs");
});

test("サービスで OS バージョンを絞り込む(ラベルにタグは出さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, readyCatalog());
  switchTo(window, document, "android");

  assert.deepEqual(optionLabels(document, "dlg-os"),
    ["Android 16(API 36) / arm64-v8a", "Android 15(API 35) / arm64-v8a"]);
  assert.equal(document.getElementById("dlg-os").value,
    "system-images;android-36;google_apis;arm64-v8a");

  const service = document.getElementById("dlg-service");
  service.value = "google_apis_playstore";
  service.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.deepEqual(optionLabels(document, "dlg-os"), ["Android 16(API 36) / arm64-v8a"],
    "Play Store 版があるのは API 36 だけ");
  assert.equal(document.getElementById("dlg-os").value,
    "system-images;android-36;google_apis_playstore;arm64-v8a");
  assert.equal(document.getElementById("dlg-ok").disabled, false);
});

test("選んだサービスのイメージが無ければ理由を出して OK を止める", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  const catalog = readyCatalog();
  // google_apis 版だけ持っている環境で Play Store を選んだ状態
  catalog.android.systemImages = catalog.android.systemImages.filter((s) => s.tag === "google_apis");
  applyCatalog(window, catalog);
  switchTo(window, document, "android");

  const service = document.getElementById("dlg-service");
  service.value = "google_apis_playstore";
  service.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(document.getElementById("dlg-os").options.length, 0);
  assert.match(document.getElementById("dlg-error").textContent, /選択したサービスのシステムイメージ/);
  assert.equal(document.getElementById("dlg-ok").disabled, true);
});

test("作成には選んだサービスのシステムイメージを渡す", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, readyCatalog());
  switchTo(window, document, "android");
  const service = document.getElementById("dlg-service");
  service.value = "google_apis_playstore";
  service.dispatchEvent(new window.Event("change", { bubbles: true }));

  document.getElementById("dlg-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const create = posted.find((m) => m.type === "createDevice");
  assert.equal(create.platform, "android");
  assert.equal(create.model, "pixel_9");
  assert.equal(create.os, "system-images;android-36;google_apis_playstore;arm64-v8a");
  // 名前はモデルと OS ラベルから自動生成される(サービスはラベルに含めない)
  assert.equal(create.name, "Pixel 9(Android 16(API 36) / arm64-v8a)");
});

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
  assert.equal(document.getElementById("dlg-os").options.length, 2, "OS バージョンは読めている");
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

test("avdmanager 不在のときだけ導入ボタンを出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());

  const row = document.getElementById("dlg-install-row");
  assert.equal(row.hidden, true, "iOS 側では出さない");

  switchTo(window, document, "android");
  assert.equal(row.hidden, false);

  // 同じ「モデルが空」でも別原因(avdmanager が動かない)なら導入では直らないので出さない
  const other = catalogWithoutAndroidModels();
  other.android.errorCode = "avdmanager-failed";
  other.android.error = "java が見つかりません";
  applyCatalog(window, other);
  assert.equal(row.hidden, true);
  assert.equal(document.getElementById("dlg-error").textContent, "java が見つかりません");
});

test("導入ボタンは押下でリクエストを送り、成功でカタログを取り直す", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());
  switchTo(window, document, "android");

  document.getElementById("dlg-install").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(posted.filter((m) => m.type === "installCmdlineToolsRequest").length, 1);
  assert.equal(document.getElementById("dlg-platform-ios").disabled, true, "導入中は選択を止める");
  // CLI が固まってもモーダルが閉じられなくならないよう、キャンセルは生かしておく
  assert.equal(document.getElementById("dlg-cancel").disabled, false);

  // 二重起動しない(完了までボタンは無効)
  document.getElementById("dlg-install").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(posted.filter((m) => m.type === "installCmdlineToolsRequest").length, 1);

  const before = posted.filter((m) => m.type === "deviceCatalogRequest").length;
  post(window, { type: "installCmdlineToolsResult", ok: true, error: null });
  assert.equal(posted.filter((m) => m.type === "deviceCatalogRequest").length, before + 1,
    "成功したらカタログを取り直す");

  // 取り直した結果 avdmanager が入っていれば、理由もボタンも消える
  const fixed = catalogWithoutAndroidModels();
  fixed.android.error = null;
  fixed.android.errorCode = null;
  fixed.android.models = [{ id: "pixel_9", name: "Pixel 9" }];
  applyCatalog(window, fixed);
  assert.equal(document.getElementById("dlg-install-row").hidden, true);
  assert.equal(document.getElementById("dlg-error").textContent, "");
  assert.equal(document.getElementById("dlg-ok").disabled, false);
});

test("導入中に閉じても、完了後に開き直せば再び押せる", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());
  switchTo(window, document, "android");
  document.getElementById("dlg-install").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  document.getElementById("dlg-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-overlay").classList.contains("visible"), false);

  // 閉じている間に終わった応答でも状態は解除する(でなければボタンは無効のまま固まる)
  post(window, { type: "installCmdlineToolsResult", ok: false, error: "通信に失敗しました" });
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());
  switchTo(window, document, "android");
  assert.equal(document.getElementById("dlg-install").disabled, false);

  const before = posted.filter((m) => m.type === "installCmdlineToolsRequest").length;
  document.getElementById("dlg-install").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(posted.filter((m) => m.type === "installCmdlineToolsRequest").length, before + 1);
});

test("導入に失敗したら理由を出して操作を戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  openDeviceAddModal(window, document);
  applyCatalog(window, catalogWithoutAndroidModels());
  switchTo(window, document, "android");
  document.getElementById("dlg-install").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  post(window, { type: "installCmdlineToolsResult", ok: false, error: "sha1 が一致しません" });
  assert.equal(document.getElementById("dlg-error").textContent, "sha1 が一致しません");
  assert.equal(document.getElementById("dlg-cancel").disabled, false, "閉じられる状態に戻る");
  assert.equal(document.getElementById("dlg-install").disabled, false, "再試行できる");
  assert.equal(document.getElementById("dlg-install-row").hidden, false);
  assert.equal(document.getElementById("dlg-ok").disabled, true, "モデルは空のままなので作成はさせない");
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

test("グループ見出しの「+」は押した側の OS 種別で開く(右上の「+」は廃止)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  assert.equal(document.getElementById("device-pick-add-new"), null, "右上の「+」は無い");

  openDeviceAddModal(window, document, "android");
  applyCatalog(window, readyCatalog());
  assert.equal(document.getElementById("dlg-platform-android").checked, true, "Android で開く");
  assert.equal(document.getElementById("dlg-service-row").hidden, false, "Android の行が出ている");
});

test("iOS 見出しの「+」は iOS で開く(前回 Android で開いた後でも)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openDeviceAddModal(window, document, "android");
  applyCatalog(window, readyCatalog());
  document.getElementById("dlg-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  applyCatalog(window, readyCatalog());
  assert.equal(document.getElementById("dlg-platform-ios").checked, true, "iOS で開く");
  assert.equal(document.getElementById("dlg-service-row").hidden, true, "Android の行は隠れる");
});

test("選べない OS 種別の「+」は、使える側へ倒れる(カタログ受信後の可用性が優先)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openDeviceAddModal(window, document, "android");
  const catalog = readyCatalog();
  catalog.android.available = false;
  applyCatalog(window, catalog);
  assert.equal(document.getElementById("dlg-platform-ios").checked, true, "iOS へ倒れる");
});
