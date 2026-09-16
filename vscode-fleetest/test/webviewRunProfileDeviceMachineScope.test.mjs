// webviewRunProfileDeviceMachineScope.test.mjs
// 実行プロファイル節のデバイス一覧(runProfileDevicesTab.js)が (platform, machine, name) で
// 行を identify することの DOM テスト。実 HTML+実バンドルで動かす方式は
// webviewRunProfileDeviceBadge.test.mjs と同じ。
//
// 同じ実行プロファイルに別マシンの同名デバイスが並ぶのは通常(各機が同じ命名規則でシミュレータを
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

// 手元とリモート(M1Max)に同名 "シミュ1" が居る実行プロファイル。表示順は [手元, M1Max]。
const DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES = [
  { platform: "ios", name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "UDID-LOCAL", enabled: true },
  { platform: "ios", name: "シミュ1", machine: "M1Max", simulator: "iPhone 16", os: "18.0", udid: "UDID-M1MAX", enabled: true },
];

const PROFILE_INFO = {
  type: "profileInfo",
  projects: ["P"], profiles: ["all"], current: "all", filter: "all", apps: [],
  project: "P", projectDir: "TestProjects/P",
  devices: DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES.map((d) => ({ ...d, detail: "iPhone 16 / 18.0" })),
};

function runProfileData(devices) {
  return {
    type: "runProfileData", profile: "all", ok: true, error: null,
    fields: {
      app: "", devices,
      heal: true, textVisualCheck: true, screenLooksLike: true, ocrTextVisualCheck: true,
      iosInappEngine: true, iosFastInput: false, iosPreActionWarmup: true, homeOnStart: true,
      playProtectBypass: true, enableAnimations: false, containerInference: true, updateWebView: true,
      wipeDataOnBloat: true, recoverCpuFallbackToGpu: false, record: false, recordFailuresOnly: false,
      recordBitrateKbps: "", recordFullResolution: false, defaultTimeout: "", wipeDataThresholdGB: "",
      locale: "", workspace: "", reportDir: "",
    },
  };
}

function postDevices(window, devices) {
  window.dispatchEvent(new window.MessageEvent("message", { data: PROFILE_INFO }));
  window.dispatchEvent(new window.MessageEvent("message", { data: runProfileData(devices) }));
}

function deviceRows(document) {
  return [...document.querySelectorAll("#run-profile-devices .run-profile-device-row-item")];
}

test("同名が別マシンに並ぶとき、クリックした行だけが選択状態になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  postDevices(window, DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES);
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

  postDevices(window, DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);

  rows[1].dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
  document.getElementById("run-profile-device-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const remoteRemove = posted.filter((m) => m.type === "runProfileDeviceRemove").pop();
  assert.equal(remoteRemove.devices.length, 1);
  assert.equal(remoteRemove.devices[0].name, "シミュ1");
  assert.equal(remoteRemove.devices[0].machine, "M1Max");

  rows[0].dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
  document.getElementById("run-profile-device-menu-item").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const localRemove = posted.filter((m) => m.type === "runProfileDeviceRemove").pop();
  assert.equal(localRemove.devices.length, 1);
  assert.equal(localRemove.devices[0].name, "シミュ1");
  assert.equal(localRemove.devices[0].machine, undefined, "手元のデバイスに machine は載せない(省略=手元)");
});

test("編集フォームの自動保存は、選択した行のマシンを載せて送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postDevices(window, DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);

  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  // 選択した行の値がフォームに載っていること(別マシンの同名を掴んでいない witness)。
  assert.equal(document.getElementById("run-profile-device-udid").textContent, "UDID-M1MAX");

  const nameInput = document.getElementById("run-profile-device-name-input");
  nameInput.value = "シミュ1-改";
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  nameInput.dispatchEvent(new window.Event("change", { bubbles: true }));

  const update = posted.filter((m) => m.type === "runProfileDeviceUpdate").pop();
  assert.equal(update.originalName, "シミュ1");
  assert.equal(update.machine, "M1Max", "その台が居る機械が載っている");
  assert.equal(update.fields.udid, "UDID-M1MAX");
});

test("手元の行の自動保存には machine を載せない(省略=手元)", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  postDevices(window, DEVICES_WITH_SAME_NAME_ON_TWO_MACHINES);
  const rows = deviceRows(document);
  rows[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("run-profile-device-udid").textContent, "UDID-LOCAL");

  const nameInput = document.getElementById("run-profile-device-name-input");
  nameInput.value = "シミュ1-改";
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  nameInput.dispatchEvent(new window.Event("change", { bubbles: true }));

  const update = posted.filter((m) => m.type === "runProfileDeviceUpdate").pop();
  assert.equal(update.machine, undefined);
});

test("別マシンの同名へのリネームは webview 側の重複検証で弾かれない", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  const devices = [
    { platform: "ios", name: "シミュA", simulator: "iPhone 16", os: "18.0", udid: "U1", enabled: true },
    { platform: "ios", name: "シミュB", machine: "M1Max", simulator: "iPhone 16", os: "18.0", udid: "U2", enabled: true },
  ];
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { ...PROFILE_INFO, devices: devices.map((d) => ({ ...d, detail: "d" })) },
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: runProfileData(devices) }));

  const rows = deviceRows(document);
  rows[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const nameInput = document.getElementById("run-profile-device-name-input");
  nameInput.value = "シミュA"; // 手元に居る名前。M1Max では未使用なので許される
  nameInput.dispatchEvent(new window.Event("input", { bubbles: true }));
  nameInput.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(document.getElementById("run-profile-device-error").textContent, "");
  const update = posted.filter((m) => m.type === "runProfileDeviceUpdate").pop();
  assert.equal(update.fields.name, "シミュA");
  assert.equal(update.machine, "M1Max");
});

// 表示順は OS(iOS → Android)→ machine(手元が先頭・以降は昇順)→ 仮想デバイス → 実機。
// 並べ替えるのは表示だけで、保存(currentDeviceEntries)はファイルの記述順のまま。
// 実機バッジは machine バッジの右に置く。
test("デバイス行は OS・machine・実機の順に並び、実機バッジは machine バッジの右に出る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  const devices = [
    { platform: "android", name: "a-local", machine: "local", avd: "A", enabled: true },
    { platform: "ios", name: "i-zeta", machine: "Zeta", udid: "U1", enabled: true },
    { platform: "ios", name: "i-phys", machine: "M1Max", kind: "physical", udid: "U2", enabled: true },
    { platform: "ios", name: "i-virt", machine: "M1Max", udid: "U3", enabled: true },
    { platform: "android", name: "a-m1", machine: "M1Max", avd: "B", enabled: true },
    { platform: "ios", name: "i-local", udid: "U4", enabled: true },
  ];
  window.dispatchEvent(new window.MessageEvent("message", { data: { ...PROFILE_INFO, apps: ["app"], devices: [] } }));
  const data = runProfileData(devices);
  window.dispatchEvent(new window.MessageEvent("message", { data: { ...data, fields: { ...data.fields, app: "app" } } }));

  const rows = deviceRows(document);
  const names = rows.map((row) => row.querySelector(".tile-name").textContent);
  assert.deepEqual(names, ["i-local", "i-virt", "i-phys", "i-zeta", "a-local", "a-m1"]);

  const physRow = rows[2];
  const badges = [...physRow.querySelectorAll(".badge")].map((b) => b.className);
  assert.deepEqual(badges, ["badge badge-remote", "badge badge-kind"], "実機バッジは machine バッジの右");
  const line = [...physRow.querySelector(".run-profile-device-name-line").children];
  assert.ok(line.indexOf(physRow.querySelector(".tile-name")) < line.indexOf(physRow.querySelector(".badge-remote")));

  // 保存は記述順のまま(チェックを1つ切り替えて保存要求を見る)
  rows[0].querySelector("input[type=checkbox]").click();
  const saved = posted.filter((m) => m.type === "runProfileSave").pop();
  assert.ok(saved, "チェックの切り替えで保存が送られる");
  assert.deepEqual([...saved.fields.devices].map((d) => String(d.name)), devices.map((d) => d.name));
});
