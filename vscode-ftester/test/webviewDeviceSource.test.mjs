// webviewDeviceSource.test.mjs
// マシンプロファイルタブ「デバイス候補の取得元」セレクタ(deviceSource.js・docs/remote-runner.md
// §13 段2)の DOM テスト。実 HTML+実バンドルで動かす方式は webviewDeviceAddModal.test.mjs と同じ
// (harness のコメントはそちら参照)。
//
// 検証対象: ①既定はローカル(source:{kind:'local'})で deviceCatalogRequest/
// installedDevicesRequest/createDevice に載る、②remoteConfig 受信でホスト一覧が選択肢になり
// 選ぶと source:{kind:'remote',host} に切り替わる、③登録簿からホストが消えたらローカルへ戻る、
// ④モーダルを開くと取得元バッジに現在の選択が出る(「黙って別マシンの一覧を出さない」)。

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

function selectMachine(window, document) {
  post(window, {
    type: "machineProfileInfo",
    machines: [{ name: "M1", devices: [] }],
    current: "M1",
    error: null,
  });
}

function openDevicePickModal(window, document) {
  selectMachine(window, document);
  document.getElementById("btn-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function openDeviceAddModal(window, document) {
  openDevicePickModal(window, document);
  document.getElementById("device-pick-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function selectSource(window, document, value) {
  const select = document.getElementById("device-source-select");
  select.value = value;
  select.dispatchEvent(new window.Event("change", { bubbles: true }));
}

// postMessage で渡るオブジェクトは jsdom(webview)側の realm で作られるため、Node 側の
// assert/strict の deepEqual(=deepStrictEqual)はプロトタイプ不一致で「構造は同じだが
// reference-equal でない」と失敗する。フィールドごとの assert.equal で比較する。
function assertLocalSource(source) {
  assert.equal(source.kind, "local");
}
function assertRemoteSource(source, host) {
  assert.equal(source.kind, "remote");
  assert.equal(source.host, host);
}

test("既定はローカル: installedDevicesRequest/deviceCatalogRequest/createDevice に source:{kind:'local'} が載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document);
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);

  document.getElementById("device-pick-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const catalogReq = posted.find((m) => m.type === "deviceCatalogRequest");
  assertLocalSource(catalogReq.source);
});

test("remoteConfig でホスト一覧が選択肢になり、選ぶと source が remote(host)になる", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, {
    type: "remoteConfig",
    hosts: [
      { name: "M1Max", host: "user@m1max", dir: "", machine: "" },
      { name: "studio", host: "studio.local", dir: "", machine: "" },
    ],
    target: "",
    artifacts: "collect",
  });

  const select = document.getElementById("device-source-select");
  assert.deepEqual([...select.options].map((o) => o.value), ["", "M1Max", "studio"]);

  selectSource(window, document, "M1Max");
  openDevicePickModal(window, document);
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertRemoteSource(installedReq.source, "M1Max");

  document.getElementById("device-pick-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const catalogReq = posted.find((m) => m.type === "deviceCatalogRequest");
  assertRemoteSource(catalogReq.source, "M1Max");
});

test("登録簿からホストが消えたら選択はローカルへ戻る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, {
    type: "remoteConfig",
    hosts: [{ name: "M1Max", host: "user@m1max", dir: "", machine: "" }],
    target: "",
    artifacts: "collect",
  });
  selectSource(window, document, "M1Max");

  // ホストが登録簿から削除される(設定タブでの削除等)
  post(window, { type: "remoteConfig", hosts: [], target: "", artifacts: "collect" });

  openDevicePickModal(window, document);
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);
  assert.equal(document.getElementById("device-source-select").value, "");
});

test("モーダルを開くと取得元バッジに現在の選択が出る(黙って別マシンの一覧を出さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, {
    type: "remoteConfig",
    hosts: [{ name: "M1Max", host: "user@m1max", dir: "", machine: "" }],
    target: "",
    artifacts: "collect",
  });

  // ローカルのまま: バッジは「ローカル」
  openDevicePickModal(window, document);
  assert.equal(document.getElementById("device-pick-source-badge").textContent, "取得元: ローカル");

  document.getElementById("device-pick-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  selectSource(window, document, "M1Max");
  openDevicePickModal(window, document);
  assert.equal(document.getElementById("device-pick-source-badge").textContent, "取得元: M1Max");

  document.getElementById("device-pick-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-source-badge").textContent, "取得元: M1Max");
});

test("createDevice にも現在の source が載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, {
    type: "remoteConfig",
    hosts: [{ name: "M1Max", host: "user@m1max", dir: "", machine: "" }],
    target: "",
    artifacts: "collect",
  });
  selectSource(window, document, "M1Max");
  openDeviceAddModal(window, document);
  post(window, {
    type: "deviceCatalog",
    ok: true,
    catalog: {
      ios: {
        available: true, error: null,
        deviceTypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", name: "iPhone 17 Pro", productFamily: "iPhone" }],
        runtimes: [{ identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0" }],
      },
      android: { available: true, error: null, models: [], systemImages: [] },
    },
    error: null,
  });

  document.getElementById("dlg-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const create = posted.find((m) => m.type === "createDevice");
  assertRemoteSource(create.source, "M1Max");
});
