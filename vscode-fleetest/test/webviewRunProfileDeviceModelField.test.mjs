// webviewRunProfileDeviceModelField.test.mjs
// devices[] の "simulator" キー廃止後の3点を実 HTML+実バンドルで確認する DOM テスト
// (harness は webviewDevicePickMachine.test.mjs / webviewRunProfileDeviceMachineScope.test.mjs と同じ)。
//
// ①「+既存から選択」の登録(runProfileDevicesSync の add[])は iOS シミュレータに simulator キーを
//   書かず、name/osVersion/udid と(取得できていれば)model を書く。model が null なら省く。
//   osVersion は installed-devices の素の os(接頭辞なし)にプラットフォーム接頭辞を足した値。
// ②右ペイン編集フォームの名前欄は iOS シミュレータ(kind !== "physical")だけ読み取り専用。
//   iOS 実機・Android(実機/エミュレータ)は編集可のまま。
// ③一覧2行目の詳細文字列(deviceDetail)は monitorProfileForms.ts の machineDeviceDetail と
//   同じ規則で出る(片方だけ変えない)。

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

const EMPTY_PROFILE_INFO = {
  type: "profileInfo",
  projects: ["P"], profiles: ["all"], current: "all", filter: "all", apps: [],
  project: "P", projectDir: "TestProjects/P", devices: [],
};

function openDevicePickModal(window, document) {
  post(window, EMPTY_PROFILE_INFO);
  document.getElementById("btn-run-profile-device-add-existing").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function checkFirstIosRow(window, document) {
  const row = document.querySelector("#device-pick-ios-body .device-pick-row input[type=checkbox]");
  row.checked = true;
  row.dispatchEvent(new window.Event("change", { bubbles: true }));
}

// ---- ① 登録(runProfileDevicesSync の add[]) ----------------------------------------------

test("「+既存から選択」の登録: iOS シミュレータは simulator キーを書かず、model が取れていれば書く", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document);
  post(window, {
    type: "installedDevices",
    ok: true,
    error: null,
    data: {
      ios: {
        available: true,
        error: null,
        devices: [{ name: "iPhone 17 Pro", udid: "UDID-1", os: "27.0", model: "iPhone 17 Pro" }],
        physicalDevices: [],
      },
      android: { available: true, error: null, avds: [], physicalDevices: [] },
    },
  });
  checkFirstIosRow(window, document);
  document.getElementById("device-pick-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const sync = posted.find((m) => m.type === "runProfileDevicesSync");
  assert.ok(sync, "runProfileDevicesSync が送られる");
  assert.equal(sync.add.length, 1);
  const entry = sync.add[0];
  assert.equal(entry.platform, "ios");
  assert.equal(entry.name, "iPhone 17 Pro");
  assert.equal(entry.osVersion, "iOS 27.0", "installed-devices の素の os にプラットフォーム接頭辞を足す");
  assert.equal(entry.udid, "UDID-1");
  assert.equal(entry.model, "iPhone 17 Pro");
  assert.equal("simulator" in entry, false, "simulator キーはもう書かない");
});

test("「+既存から選択」の登録: iOS シミュレータの model が null(取得できず)ならキー自体を省く", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document);
  post(window, {
    type: "installedDevices",
    ok: true,
    error: null,
    data: {
      ios: {
        available: true,
        error: null,
        devices: [{ name: "iPhone 17 Pro", udid: "UDID-1", os: "27.0", model: null }],
        physicalDevices: [],
      },
      android: { available: true, error: null, avds: [], physicalDevices: [] },
    },
  });
  checkFirstIosRow(window, document);
  document.getElementById("device-pick-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const sync = posted.find((m) => m.type === "runProfileDevicesSync");
  const entry = sync.add[0];
  assert.equal("model" in entry, false, "null は書かない(欄自体を省く)");
  assert.equal("simulator" in entry, false);
});

test("「+既存から選択」の登録: Android 実機は installed-devices の素の os にプラットフォーム接頭辞を足して osVersion を書く", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openDevicePickModal(window, document);
  post(window, {
    type: "installedDevices",
    ok: true,
    error: null,
    data: {
      ios: { available: true, error: null, devices: [], physicalDevices: [] },
      android: {
        available: true,
        error: null,
        avds: [],
        physicalDevices: [{ model: "Pixel 8", serial: "14141JEC204922", os: "13" }],
      },
    },
  });
  const row = document.querySelector("#device-pick-android-body .device-pick-row input[type=checkbox]");
  row.checked = true;
  row.dispatchEvent(new window.Event("change", { bubbles: true }));
  document.getElementById("device-pick-ok").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const sync = posted.find((m) => m.type === "runProfileDevicesSync");
  assert.ok(sync, "runProfileDevicesSync が送られる");
  const entry = sync.add[0];
  assert.equal(entry.platform, "android");
  assert.equal(entry.kind, "physical");
  assert.equal(entry.serial, "14141JEC204922");
  assert.equal(entry.osVersion, "Android 13");
});

// ---- ② 名前欄はどの種別も表示専用ラベル(実体を指す属性で API では改名不可) -------------------

const PROFILE_INFO_FOR_EDITOR = {
  type: "profileInfo",
  projects: ["P"], profiles: ["all"], current: "all", filter: "all", apps: [],
  project: "P", projectDir: "TestProjects/P",
  devices: [
    { platform: "ios", name: "シミュ1", model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1", detail: "d" },
    { platform: "ios", name: "実機1", machine: "M1Max", kind: "physical", model: "iPhone 15", osVersion: "iOS 18.0", udid: "U2", detail: "d" },
    { platform: "android", name: "エミュ1", avd: "Pixel_9", detail: "d" },
    { platform: "android", name: "実機2", kind: "physical", model: "Pixel 8", osVersion: "Android 15", serial: "S1", detail: "d" },
  ],
};

function runProfileDataWithDevices(devices) {
  return { type: "runProfileData", profile: "all", ok: true, error: null, fields: { app: "", devices } };
}

function selectDeviceByName(document, window, name) {
  const rows = [...document.querySelectorAll("#run-profile-devices .run-profile-device-row-item")];
  const row = rows.find((r) => r.querySelector(".tile-name").textContent === name);
  row.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

test("名前欄: iOS シミュレータ・iOS実機・Androidエミュレータ・Android実機のすべてで #run-profile-device-name-static に名前が出て、入力欄は存在しない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, PROFILE_INFO_FOR_EDITOR);
  post(window, runProfileDataWithDevices([
    { platform: "ios", name: "シミュ1", enabled: true, model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" },
    { platform: "ios", name: "実機1", enabled: true, machine: "M1Max", kind: "physical", model: "iPhone 15", osVersion: "iOS 18.0", udid: "U2" },
    { platform: "android", name: "エミュ1", enabled: true, avd: "Pixel_9" },
    { platform: "android", name: "実機2", enabled: true, kind: "physical", model: "Pixel 8", osVersion: "Android 15", serial: "S1" },
  ]));

  assert.equal(document.getElementById("run-profile-device-name-input"), null, "入力欄はもう無い");
  assert.equal(document.querySelectorAll("#run-profile-device-editor input").length, 0, "詳細ペインに input は1つも無い");

  for (const name of ["シミュ1", "実機1", "エミュ1", "実機2"]) {
    selectDeviceByName(document, window, name);
    const nameStatic = document.getElementById("run-profile-device-name-static");
    assert.notEqual(nameStatic.style.display, "none", `${name} は表示される`);
    assert.equal(nameStatic.textContent, name);
    assert.equal(nameStatic.className, "editor-readonly-value");
  }
});

test("名前欄のツールチップ: 改名不可の理由が出るのは iOS シミュレータだけ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, PROFILE_INFO_FOR_EDITOR);
  post(window, runProfileDataWithDevices([
    { platform: "ios", name: "シミュ1", enabled: true, model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" },
    { platform: "ios", name: "実機1", enabled: true, machine: "M1Max", kind: "physical", model: "iPhone 15", osVersion: "iOS 18.0", udid: "U2" },
    { platform: "android", name: "エミュ1", enabled: true, avd: "Pixel_9" },
    { platform: "android", name: "実機2", enabled: true, kind: "physical", model: "Pixel 8", osVersion: "Android 15", serial: "S1" },
  ]));

  selectDeviceByName(document, window, "シミュ1");
  assert.notEqual(document.getElementById("run-profile-device-name-static").title, "", "理由を示すツールチップを持つ");

  for (const name of ["実機1", "エミュ1", "実機2"]) {
    selectDeviceByName(document, window, name);
    assert.equal(document.getElementById("run-profile-device-name-static").title, "", `${name} にはツールチップが無い`);
  }
});

test("名前の右のバッジ: iOS実機(machine M1Max)は [名前, machine バッジ, 実機バッジ] の順で出て、手元のエミュレータはどちらも出ない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, PROFILE_INFO_FOR_EDITOR);
  post(window, runProfileDataWithDevices([
    { platform: "ios", name: "実機1", enabled: true, machine: "M1Max", kind: "physical", model: "iPhone 15", osVersion: "iOS 18.0", udid: "U2" },
    { platform: "android", name: "エミュ1", enabled: true, avd: "Pixel_9" },
  ]));

  selectDeviceByName(document, window, "実機1");
  const nameRow = document.getElementById("run-profile-device-name-static").parentElement;
  const visibleIds = [...nameRow.children]
    .filter((el) => el.tagName !== "LABEL" && el.style.display !== "none")
    .map((el) => el.id);
  assert.deepEqual(visibleIds, [
    "run-profile-device-name-static",
    "run-profile-device-name-machine-badge",
    "run-profile-device-name-kind-badge",
  ]);
  assert.equal(document.getElementById("run-profile-device-name-machine-badge").textContent, "M1Max");
  assert.equal(document.getElementById("run-profile-device-name-kind-badge").textContent, "実機");

  selectDeviceByName(document, window, "エミュ1");
  assert.equal(document.getElementById("run-profile-device-name-machine-badge").style.display, "none");
  assert.equal(document.getElementById("run-profile-device-name-kind-badge").style.display, "none");
});

// ---- ③ Model 行の表示・一覧の詳細文字列 -------------------------------------------------

test("Model 行: iOS シミュレータの model を表示し、無ければ隠す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, PROFILE_INFO_FOR_EDITOR);
  post(window, runProfileDataWithDevices([
    { platform: "ios", name: "シミュ1", enabled: true, model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" },
    { platform: "ios", name: "シミュ2", enabled: true, osVersion: "iOS 18.0", udid: "U3" }, // model 無し
  ]));

  selectDeviceByName(document, window, "シミュ1");
  assert.equal(document.getElementById("run-profile-device-model-row").style.display, "");
  assert.equal(document.getElementById("run-profile-device-model").textContent, "iPhone 16");

  selectDeviceByName(document, window, "シミュ2");
  assert.equal(document.getElementById("run-profile-device-model-row").style.display, "none");
});

test("編集フォームの行ラベル: 機種/OS は英語表記の \"Model\" / \"OS Version\"", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, PROFILE_INFO_FOR_EDITOR);
  post(window, runProfileDataWithDevices([
    { platform: "ios", name: "シミュ1", enabled: true, model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" },
    { platform: "android", name: "実機2", enabled: true, kind: "physical", model: "Pixel 8", osVersion: "Android 15", serial: "S1" },
  ]));

  selectDeviceByName(document, window, "シミュ1");
  assert.equal(document.querySelector("#run-profile-device-os-row label").textContent, "OS Version");

  selectDeviceByName(document, window, "実機2");
  assert.equal(document.querySelector("#run-profile-device-model-row label").textContent, "Model");
  assert.equal(document.querySelector("#run-profile-device-physical-os-row label").textContent, "OS Version");
  assert.equal(document.querySelector("#run-profile-device-serial-row label").textContent, "Serial");
});

test("一覧の詳細文字列: iOS/Android は machineDeviceDetail と同じ規則で出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    ...PROFILE_INFO_FOR_EDITOR,
    devices: PROFILE_INFO_FOR_EDITOR.devices.map((d) => ({ ...d, detail: "unused" })),
  });
  post(window, runProfileDataWithDevices(PROFILE_INFO_FOR_EDITOR.devices.map((d) => ({ ...d, enabled: true }))));

  const detailFor = (name) => {
    const rows = [...document.querySelectorAll("#run-profile-devices .run-profile-device-row-item")];
    const row = rows.find((r) => r.querySelector(".tile-name").textContent === name);
    return row.querySelector(".run-profile-device-detail").textContent;
  };
  assert.equal(detailFor("シミュ1"), "iPhone 16 / iOS 18.0");
  assert.equal(detailFor("実機1"), "iPhone 15 / iOS 18.0");
  assert.equal(detailFor("エミュ1"), "AVD: Pixel_9");
  assert.equal(detailFor("実機2"), "Pixel 8 / Android 15");
});
