// webviewDevicePickHost.test.mjs
// #device-pick-overlay(「+既存から選択」モーダル)内のホスト選択(devicePickHost.js)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewDeviceAddModal.test.mjs と同じ(harness のコメントは
// そちら参照)。旧 test/webviewDeviceSource.test.mjs(常設セレクタ #device-source-select)を置き換える。
//
// 検証対象: ①マシンプロファイルに host が無ければ既定はローカル(source:{kind:'local'})で
// deviceCatalogRequest/installedDevicesRequest/createDevice に載る、②マシンプロファイルの host が
// 登録済みホスト名ならそのホストが初期値になり同じ3メッセージに remote(host)が載る、③登録簿に
// 無いホストを指していればローカルへ落ちる、④ダイアログを開いたまま選び直すと installed-devices を
// 選び直したホストで再取得する、⑤ホストバッジ(#device-add-source-badge)に現在の選択が出る、
// ⑥machineDevicesSync(OK ボタン)にも現在の選択が source として載る。

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

function selectMachine(window, document, machine) {
  post(window, {
    type: "machineProfileInfo",
    machines: [machine],
    current: machine.name,
    error: null,
  });
}

function openDevicePickModal(window, document, machine) {
  selectMachine(window, document, machine);
  document.getElementById("btn-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function selectHost(window, document, value) {
  const select = document.getElementById("device-pick-host-select");
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

const REMOTE_CONFIG_WITH_M1MAX = {
  type: "remoteConfig",
  hosts: [{ name: "M1Max", host: "user@m1max", dir: "", machine: "" }],
  artifacts: "collect",
};

const EMPTY_INSTALLED_DEVICES = {
  type: "installedDevices",
  ok: true,
  error: null,
  data: {
    ios: { available: true, error: null, devices: [], physicalDevices: [] },
    android: { available: true, error: null, avds: [], physicalDevices: [] },
  },
};

test("host 未設定のマシンは既定でローカル(installedDevicesRequest/deviceCatalogRequest/createDevice に source:{kind:'local'})", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);
  assert.equal(document.getElementById("device-pick-host-select").value, "");

  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const catalogReq = posted.find((m) => m.type === "deviceCatalogRequest");
  assertLocalSource(catalogReq.source);
});

test("マシンの host が登録済みホスト名なら、それが初期値になり同じ3メッセージに remote(host) が載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document, { name: "M1", devices: [], host: "M1Max" });

  assert.equal(document.getElementById("device-pick-host-select").value, "M1Max");
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertRemoteSource(installedReq.source, "M1Max");

  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const catalogReq = posted.find((m) => m.type === "deviceCatalogRequest");
  assertRemoteSource(catalogReq.source, "M1Max");
});

test("マシンの host が登録簿に無い名前ならローカルへ落ちる", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document, { name: "M1", devices: [], host: "GoneHost" });

  assert.equal(document.getElementById("device-pick-host-select").value, "");
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);
});

test("ダイアログを開いたまま選び直すと installedDevicesRequest を選び直したホストで再送する", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document, { name: "M1", devices: [] });
  assert.equal(posted.filter((m) => m.type === "installedDevicesRequest").length, 1);

  selectHost(window, document, "M1Max");
  const requests = posted.filter((m) => m.type === "installedDevicesRequest");
  assert.equal(requests.length, 2, "選び直しで再要求する");
  assertRemoteSource(requests[1].source, "M1Max");
});

test("ホストバッジ(#device-add-source-badge)に現在の選択が出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);

  // ローカルのまま: バッジは「ローカル」
  openDevicePickModal(window, document, { name: "M1", devices: [] });
  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-source-badge").textContent, "ホスト: ローカル");
  document.getElementById("dlg-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  document.getElementById("device-pick-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  // host: M1Max のマシンを開き直す: バッジは「M1Max」
  openDevicePickModal(window, document, { name: "M1", devices: [], host: "M1Max" });
  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-source-badge").textContent, "ホスト: M1Max");
});

test("machineDevicesSync(OK ボタン)にも現在選択中のホストが source として載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document, { name: "M1", devices: [], host: "M1Max" });

  post(window, {
    type: "installedDevices",
    ok: true,
    error: null,
    data: {
      ios: {
        available: true,
        error: null,
        devices: [{ name: "iPhone 17 Pro", udid: "UDID-1", os: "27.0" }],
        physicalDevices: [],
      },
      android: { available: true, error: null, avds: [], physicalDevices: [] },
    },
  });

  // 未登録デバイス行をチェックして add を発生させる。
  const row = document.querySelector("#device-pick-ios-body .device-pick-row input[type=checkbox]");
  row.checked = true;
  row.dispatchEvent(new window.Event("change", { bubbles: true }));

  document.getElementById("device-pick-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const sync = posted.find((m) => m.type === "machineDevicesSync");
  assert.ok(sync, "machineDevicesSync が送られる");
  assertRemoteSource(sync.source, "M1Max");
});
