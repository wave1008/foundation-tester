// webviewDevicePickDelete.test.mjs
// #device-pick-overlay(「+既存から選択」モーダル)内、行右クリック「削除」(#device-pick-delete-menu)
// の DOM テスト。実 HTML+実バンドルで動かす方式は webviewDevicePickHost.test.mjs と同じ(harness の
// コメントはそちら参照)。machineDeviceRemove(プロファイルからの除去)とは別物 —— こちらはホスト上の
// 実体(シミュレータ/AVD)を ftester api delete-device で消す想定の devicePickDeviceDelete を送る。
//
// 検証対象: ①シミュレータ/AVD 行の右クリックで devicePickDeviceDelete が platform/identifier/name/
// source 付きで送られ、送信直後にその行の checkbox が disabled になる、②実機行には削除メニューが
// 出ない(実体を持たないため)、③devicePickDeviceDeleteResult(ok:true)で一覧を再取得する、
// ④ok:false ではエラー文言を #device-pick-error に出し、行の checkbox を再度有効化する。

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

const INSTALLED_DEVICES_WITH_ROWS = {
  type: "installedDevices",
  ok: true,
  error: null,
  data: {
    ios: {
      available: true,
      error: null,
      devices: [{ name: "iPhone 17 Pro", udid: "SIM-UDID-1", os: "27.0" }],
      physicalDevices: [
        { name: "実機iPhone", udid: "PHYS-UDID-1", os: "18.0", transport: "wired", model: "iPhone 16" },
      ],
    },
    android: {
      available: true,
      error: null,
      avds: [{ displayName: "Pixel 9 (API 37)", id: "Pixel_9_API_37" }],
      physicalDevices: [],
    },
  },
};

function rightClick(window, el) {
  el.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
}

test("シミュレータ行の右クリック→削除で devicePickDeviceDelete(platform/identifier/name/source)を送り、送信直後にその行の checkbox を disabled にする", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  post(window, INSTALLED_DEVICES_WITH_ROWS);

  // iOS グループは実機が先頭に出るため、シミュレータ行は2件目。
  const iosRows = document.querySelectorAll("#device-pick-ios-body .device-pick-row");
  const simRow = iosRows[iosRows.length - 1];
  rightClick(window, simRow);

  const menu = document.getElementById("device-pick-delete-menu");
  assert.ok(menu.classList.contains("visible"), "削除メニューが開く");

  document.getElementById("device-pick-delete-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const deleteMsg = posted.find((m) => m.type === "devicePickDeviceDelete");
  assert.ok(deleteMsg, "devicePickDeviceDelete が送られる");
  assert.equal(deleteMsg.platform, "ios");
  assert.equal(deleteMsg.identifier, "SIM-UDID-1");
  assert.equal(deleteMsg.name, "iPhone 17 Pro");
  assert.equal(deleteMsg.source.kind, "local");

  assert.ok(!menu.classList.contains("visible"), "選択後はメニューが閉じる");
  assert.ok(simRow.classList.contains("deleting"), "送信直後はその行が deleting 状態になる");
  assert.equal(simRow.querySelector("input[type=checkbox]").disabled, true);
});

test("Android AVD 行の右クリック→削除で devicePickDeviceDelete(platform:'android', identifier:avd.id)を送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  post(window, INSTALLED_DEVICES_WITH_ROWS);

  const avdRow = document.querySelector("#device-pick-android-body .device-pick-row");
  rightClick(window, avdRow);
  document.getElementById("device-pick-delete-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const deleteMsg = posted.find((m) => m.type === "devicePickDeviceDelete");
  assert.ok(deleteMsg);
  assert.equal(deleteMsg.platform, "android");
  assert.equal(deleteMsg.identifier, "Pixel_9_API_37");
  assert.equal(deleteMsg.name, "Pixel 9 (API 37)");
});

test("実機行を右クリックしても削除メニューは出ない(実体を持たないため)", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  post(window, INSTALLED_DEVICES_WITH_ROWS);

  const iosRows = document.querySelectorAll("#device-pick-ios-body .device-pick-row");
  const physicalRow = iosRows[0];
  rightClick(window, physicalRow);

  const menu = document.getElementById("device-pick-delete-menu");
  assert.ok(!menu.classList.contains("visible"), "実機行では削除メニューが開かない");
  assert.equal(posted.some((m) => m.type === "devicePickDeviceDelete"), false);
});

test("devicePickDeviceDeleteResult(ok:true)を受けると一覧を再取得し、その行の deleting 状態が解ける", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  post(window, INSTALLED_DEVICES_WITH_ROWS);
  assert.equal(posted.filter((m) => m.type === "installedDevicesRequest").length, 1);

  const iosRows = document.querySelectorAll("#device-pick-ios-body .device-pick-row");
  const simRow = iosRows[iosRows.length - 1];
  rightClick(window, simRow);
  document.getElementById("device-pick-delete-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(simRow.classList.contains("deleting"));

  post(window, {
    type: "devicePickDeviceDeleteResult",
    ok: true,
    identifier: "SIM-UDID-1",
    name: "iPhone 17 Pro",
    error: null,
    referencedBy: [],
  });

  assert.equal(
    posted.filter((m) => m.type === "installedDevicesRequest").length,
    2,
    "成功後に一覧を取り直す",
  );
});

test("devicePickDeviceDeleteResult(ok:false)は #device-pick-error にエラー文言を出し、行の checkbox を再度有効化する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openDevicePickModal(window, document, { name: "M1", devices: [] });
  post(window, INSTALLED_DEVICES_WITH_ROWS);

  const iosRows = document.querySelectorAll("#device-pick-ios-body .device-pick-row");
  const simRow = iosRows[iosRows.length - 1];
  rightClick(window, simRow);
  document.getElementById("device-pick-delete-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  post(window, {
    type: "devicePickDeviceDeleteResult",
    ok: false,
    identifier: "SIM-UDID-1",
    name: "iPhone 17 Pro",
    error: "起動中のため削除できません(ホスト: M1Max)",
    referencedBy: [],
  });

  assert.equal(document.getElementById("device-pick-error").textContent, "起動中のため削除できません(ホスト: M1Max)");
  assert.ok(!simRow.classList.contains("deleting"), "失敗後は deleting 状態が解ける");
  assert.equal(simRow.querySelector("input[type=checkbox]").disabled, false);
});
