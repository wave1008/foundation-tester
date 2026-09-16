// webviewDevicePickMachine.test.mjs
// #device-pick-overlay(「+既存から選択」モーダル)内のマシン選択(devicePickMachine.js)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewDeviceAddModal.test.mjs と同じ(harness のコメントは
// そちら参照)。
//
// **実行プロファイルは単独の既定ホストを持たない**ため、このダイアログの
// マシン選択は開くたびに必ずローカルへ戻る(resetDevicePickMachine に引数は無い)。
//
// 検証対象: ①開いた直後の既定はローカル(source:{kind:'local'})で
// deviceCatalogRequest/installedDevicesRequest/createDevice に載る、②ダイアログを開くたびに
// ローカルへリセットされる(前回選んだマシンを引き継がない)、③ダイアログを開いたまま選び直すと
// installed-devices を選び直したマシンで再取得する、④マシンバッジ(#device-add-source-badge)に
// 現在の選択が出る、⑤runProfileDevicesSync(OK ボタン)にも現在の選択が source として載る。

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

function openDevicePickModal(window, document) {
  post(window, {
    type: "profileInfo",
    projects: ["P"], profiles: ["all"], current: "all", filter: "all", apps: [],
    project: "P", projectDir: "TestProjects/P", devices: [],
  });
  document.getElementById("btn-run-profile-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function pickMachineOption(window, document, value) {
  const select = document.getElementById("device-pick-machine-select");
  select.value = value;
  select.dispatchEvent(new window.Event("change", { bubbles: true }));
}

// postMessage で渡るオブジェクトは jsdom(webview)側の realm で作られるため、Node 側の
// assert/strict の deepEqual(=deepStrictEqual)はプロトタイプ不一致で「構造は同じだが
// reference-equal でない」と失敗する。フィールドごとの assert.equal で比較する。
function assertLocalSource(source) {
  assert.equal(source.kind, "local");
}
function assertRemoteSource(source, machine) {
  assert.equal(source.kind, "remote");
  assert.equal(source.machine, machine);
}

// **マシン名のキーは "machine"**(2026-08-26 改名。remoteRunArgs.ts の RemoteHostEntry と対)。
// 旧キー "name" のままにすると一覧が空になり、リモートのマシンを1つも選べない。
const REMOTE_CONFIG_WITH_M1MAX = {
  type: "remoteConfig",
  hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
};

test("開いた直後の既定はローカル(installedDevicesRequest/deviceCatalogRequest/createDevice に source:{kind:'local'})", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document);
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);
  assert.equal(document.getElementById("device-pick-machine-select").value, "");

  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const catalogReq = posted.find((m) => m.type === "deviceCatalogRequest");
  assertLocalSource(catalogReq.source);
});

test("開くたびにローカルへリセットする(実行プロファイルは単独の既定ホストを持たないため、前回選んだマシンを引き継がない)", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document);
  pickMachineOption(window, document, "M1Max");
  assert.equal(document.getElementById("device-pick-machine-select").value, "M1Max");
  document.getElementById("device-pick-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  posted.length = 0;
  openDevicePickModal(window, document);
  assert.equal(document.getElementById("device-pick-machine-select").value, "", "開き直すとローカルへ戻る");
  const installedReq = posted.find((m) => m.type === "installedDevicesRequest");
  assertLocalSource(installedReq.source);
});

test("ダイアログを開いたまま選び直すと installedDevicesRequest を選び直したマシンで再送する", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document);
  assert.equal(posted.filter((m) => m.type === "installedDevicesRequest").length, 1);

  pickMachineOption(window, document, "M1Max");
  const requests = posted.filter((m) => m.type === "installedDevicesRequest");
  assert.equal(requests.length, 2, "選び直しで再要求する");
  assertRemoteSource(requests[1].source, "M1Max");
});

test("マシンバッジ(#device-add-source-badge)に現在の選択が出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);

  // ローカルのまま: バッジは「ローカル」
  openDevicePickModal(window, document);
  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-source-badge").textContent, "マシン: ローカル");
  document.getElementById("dlg-cancel").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  // M1Max を選び直す: バッジは「M1Max」
  pickMachineOption(window, document, "M1Max");
  document.getElementById("device-pick-ios-add-new").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("device-add-source-badge").textContent, "マシン: M1Max");
});

test("runProfileDevicesSync(OK ボタン)にも現在選択中のマシンが source として載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG_WITH_M1MAX);
  openDevicePickModal(window, document);
  pickMachineOption(window, document, "M1Max");

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
  const sync = posted.find((m) => m.type === "runProfileDevicesSync");
  assert.ok(sync, "runProfileDevicesSync が送られる");
  assertRemoteSource(sync.source, "M1Max");
});
