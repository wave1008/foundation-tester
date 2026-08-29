// webviewMachineDeviceWipe.test.mjs
// マシンプロファイルのデバイス行右クリック「Wipe Data」(machineProfilesTab.js)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewMachineDeviceMachineScope.test.mjs と同じ。
//
// 守りたいのは3つ: ①**実機の行には出さない**(端末を初期化する操作は持たない。1台でも実機が
// 混ざる選択でも出さない —— 一部だけ実行すると何が消えたのか分からなくなる)
// ②宛先は**識別子**(iOS=udid / Android=avd)で送る —— CLI は名前を引かない(プロファイルを
// 参照しない契約)。どの機械の台かは machine で伝える
// ③識別子を持たない行では出さない(撃ちようがない)。

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

// 仮想デバイス2台(手元/M1Max。同名)+ 実機1台。
const MACHINE = {
  name: "M1",
  devices: [
    { name: "エミュ1", platform: "android", detail: "Pixel 8", avd: "Pixel_8_LOCAL" },
    { name: "エミュ1", platform: "android", machine: "M1Max", detail: "Pixel 8", avd: "Pixel_8_M1MAX" },
    { name: "iPhone実機", platform: "ios", kind: "physical", detail: "iPhone 16", udid: "UDID-PHYS" },
    // avd 未設定 = 撃つ宛先が無い(そもそも wipe できない)
    { name: "エミュ(avd未設定)", platform: "android", detail: "Pixel 3a" },
    { name: "シミュ1", platform: "ios", detail: "iPhone 17 Pro", udid: "UDID-SIM1" },
  ],
};

function postMachine(window, machine) {
  window.dispatchEvent(
    new window.MessageEvent("message", {
      data: { type: "machineProfileInfo", machines: [machine], current: machine.name, error: null },
    }),
  );
}

function deviceRows(document) {
  return [...document.querySelectorAll("#machine-device-list .machine-device-row")];
}

function openMenuOn(window, row) {
  row.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
}

test("仮想デバイスの行には Wipe Data を出し、その行のマシンを載せて送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, MACHINE);
  const rows = deviceRows(document);
  const wipeItem = document.getElementById("machine-device-menu-wipe");

  openMenuOn(window, rows[1]);
  assert.notEqual(wipeItem.style.display, "none", "仮想デバイスの行で Wipe Data が隠れている");
  wipeItem.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const remote = posted.filter((m) => m.type === "machineDeviceWipe").pop();
  assert.equal(remote.devices.length, 1);
  assert.equal(remote.devices[0].platform, "android");
  assert.equal(remote.devices[0].identifier, "Pixel_8_M1MAX", "その行の avd を送る(同名でも別の台)");
  assert.equal(remote.devices[0].machine, "M1Max");

  openMenuOn(window, rows[0]);
  wipeItem.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const local = posted.filter((m) => m.type === "machineDeviceWipe").pop();
  assert.equal(local.devices.length, 1);
  assert.equal(local.devices[0].identifier, "Pixel_8_LOCAL");
  assert.equal(local.devices[0].machine, undefined, "手元のデバイスに machine は載せない(省略=手元)");
});

test("iOS の行は udid を送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, MACHINE);
  const rows = deviceRows(document);
  openMenuOn(window, rows[4]);
  document.getElementById("machine-device-menu-wipe").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const sent = posted.filter((m) => m.type === "machineDeviceWipe").pop();
  assert.equal(sent.devices[0].platform, "ios");
  assert.equal(sent.devices[0].identifier, "UDID-SIM1");
});

test("識別子(avd/udid)を持たない行では Wipe Data を出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  postMachine(window, MACHINE);
  const rows = deviceRows(document);
  openMenuOn(window, rows[3]);
  assert.equal(document.getElementById("machine-device-menu-wipe").style.display, "none");
});

test("実機の行では Wipe Data を出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  postMachine(window, MACHINE);
  const rows = deviceRows(document);
  openMenuOn(window, rows[2]);
  assert.equal(document.getElementById("machine-device-menu-wipe").style.display, "none");
  // 「除去」は実機でも出る(登録から外すだけで端末には触らない)
  assert.notEqual(document.getElementById("machine-device-menu-item").style.display, "none");
});

test("実機が1台でも混ざる複数選択では Wipe Data を出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  postMachine(window, MACHINE);
  const rows = deviceRows(document);
  const wipeItem = document.getElementById("machine-device-menu-wipe");

  // 仮想2台だけの複数選択では出る
  rows[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true, metaKey: true }));
  openMenuOn(window, rows[1]);
  assert.notEqual(wipeItem.style.display, "none");

  // そこへ実機を足すと消える
  rows[2].dispatchEvent(new window.MouseEvent("click", { bubbles: true, metaKey: true }));
  openMenuOn(window, rows[2]);
  assert.equal(wipeItem.style.display, "none");
});
