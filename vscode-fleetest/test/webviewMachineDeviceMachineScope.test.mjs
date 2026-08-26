// webviewMachineDeviceMachineScope.test.mjs
// マシンプロファイルのデバイス一覧(machineProfilesTab.js)が (machine, name) で行を identify することの
// DOM テスト。実 HTML+実バンドルで動かす方式は webviewDevicePickHost.test.mjs と同じ。
//
// 同じ機械プロファイルに別マシンの同名デバイスが並ぶのは通常(各機が同じ命名規則でシミュレータを
// 作る)。名前だけで持つと、①クリックした行と別マシンの同名行が選択状態になり、②右クリック
// メニューの除去・編集フォームの確定が別の機械のエントリへ飛ぶ。

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

// 手元とリモート(M1Max)に同名 "シミュ1" が居るマシンプロファイル。表示順は [手元, M1Max]。
const MACHINE_WITH_SAME_NAME_ON_TWO_MACHINES = {
  name: "M1",
  devices: [
    { name: "シミュ1", platform: "ios", detail: "iPhone 16 / 18.0", simulator: "iPhone 16", os: "18.0", udid: "UDID-LOCAL" },
    {
      name: "シミュ1",
      platform: "ios",
      machine: "M1Max",
      detail: "iPhone 16 / 18.0",
      simulator: "iPhone 16",
      os: "18.0",
      udid: "UDID-M1MAX",
    },
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

test("同名が別マシンに並ぶとき、クリックした行だけが選択状態になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  postMachine(window, MACHINE_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);
  assert.equal(rows.length, 2);

  rows[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(rows[0].classList.contains("selected"), true);
  assert.equal(rows[1].classList.contains("selected"), false, "別マシンの同名行が巻き添えで選択されている");

  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(rows[0].classList.contains("selected"), false);
  assert.equal(rows[1].classList.contains("selected"), true);
});

test("右クリック→除去は、その行のマシンを載せて送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, MACHINE_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);

  rows[1].dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
  document.getElementById("machine-device-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const remoteRemove = posted.filter((m) => m.type === "machineDeviceRemove").pop();
  assert.equal(remoteRemove.devices.length, 1);
  assert.equal(remoteRemove.devices[0].name, "シミュ1");
  assert.equal(remoteRemove.devices[0].machine, "M1Max");

  rows[0].dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
  document.getElementById("machine-device-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const localRemove = posted.filter((m) => m.type === "machineDeviceRemove").pop();
  assert.equal(localRemove.devices.length, 1);
  assert.equal(localRemove.devices[0].name, "シミュ1");
  assert.equal(localRemove.devices[0].machine, undefined, "手元のデバイスに machine は載せない(省略=手元)");
});

test("編集フォームの確定は、選択した行のマシンを載せて送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, MACHINE_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);

  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  // 選択した行の値がフォームに載っていること(別マシンの同名を掴んでいない witness)。
  assert.equal(document.getElementById("editor-udid").textContent, "UDID-M1MAX");

  const nameInput = document.getElementById("editor-name");
  nameInput.value = "シミュ1-改";
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  document.getElementById("editor-confirm").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const update = posted.filter((m) => m.type === "machineDeviceUpdate").pop();
  assert.equal(update.originalName, "シミュ1");
  assert.equal(update.deviceMachine, "M1Max");
  assert.equal(update.fields.udid, "UDID-M1MAX");
});

test("手元の行の確定には deviceMachine を載せない(省略=手元)", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, MACHINE_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);
  rows[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("editor-udid").textContent, "UDID-LOCAL");

  const nameInput = document.getElementById("editor-name");
  nameInput.value = "シミュ1-改";
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  document.getElementById("editor-confirm").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const update = posted.filter((m) => m.type === "machineDeviceUpdate").pop();
  assert.equal(update.deviceMachine, undefined);
});

test("別マシンの同名へのリネームは webview 側の重複検証で弾かれない", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postMachine(window, {
    name: "M1",
    devices: [
      { name: "シミュA", platform: "ios", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "U1" },
      { name: "シミュB", platform: "ios", machine: "M1Max", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "U2" },
    ],
  });
  const rows = deviceRows(document);
  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const nameInput = document.getElementById("editor-name");
  nameInput.value = "シミュA"; // 手元に居る名前。M1Max では未使用なので許される
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  document.getElementById("editor-confirm").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  assert.equal(document.getElementById("editor-error").textContent, "");
  const update = posted.filter((m) => m.type === "machineDeviceUpdate").pop();
  assert.equal(update.fields.name, "シミュA");
  assert.equal(update.deviceMachine, "M1Max");
});
