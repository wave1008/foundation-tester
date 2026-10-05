// webviewProfilePlatformScope.test.mjs
// 対象 OS(アプリプロファイルの最上位 platform)を実 HTML+実バンドル+実 style.css で確かめる
// DOM E2E(jsdom)。ハーネスは test/webviewAppProfilePhysicalPath.test.mjs と同じ。
// - アプリプロファイル: ラジオが platform を読み書きし(自動保存)、選んでいない OS の欄を隠す
// - 実行プロファイル: 参照するアプリの platform を継承してセクションとデバイス一覧を絞る。
//   対象外 OS のデバイスは表示だけ落として警告し、保存では JSON に残す(実行時の無視は Swift 側)
// 隠すのは CSS([data-platform-scope])なので、style.css を流し込んで計算後の display を見る。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
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
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" },
    { path: "" },
  );

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

const styleCss = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");

function createWebview(t) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  t.after(() => window.close());
  const style = window.document.createElement("style");
  style.textContent = styleCss;
  window.document.head.appendChild(style);
  const posted = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  const send = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return { window, posted, send };
}

function profileInfo(appPlatforms) {
  return {
    type: "profileInfo",
    profiles: ["run-1"],
    current: "run-1",
    filter: "all",
    apps: ["ios-app", "android-app", "both-app"],
    appPlatforms,
    project: "SampleApp",
  };
}

const PLATFORMS = { "ios-app": "ios", "android-app": "android", "both-app": "hybrid" };

function appProfileData(platform) {
  return {
    type: "appProfileData",
    profile: "ios-app",
    ok: true,
    error: null,
    fields: {
      platform,
      autoInstall: "true",
      ios: { appName: "Sample", app: "com.example.ios", appPath: "a.app", appPathPhysical: "" },
      android: { appName: "Sample", app: "com.example.android", appPath: "a.apk" },
    },
  };
}

const IOS_SIM = { platform: "ios", name: "iPhone 17", enabled: true, udid: "U1", osVersion: "iOS 27.0" };
const ANDROID_EMU = { platform: "android", name: "Pixel 9", enabled: true, avd: "Pixel_9" };
const ANDROID_OFF = { platform: "android", name: "Pixel 8", enabled: false, avd: "Pixel_8" };

function runProfileData(app, devices) {
  return {
    type: "runProfileData",
    profile: "run-1",
    ok: true,
    error: null,
    fields: {
      app,
      devices,
      heal: true,
      fmTextOcclusionCheck: true,
      screenLooksLike: true,
      containerInference: true,
      ocrTextOcclusionCheck: true,
      preferCheckStateClassifier: true,
      iosInappEngine: true,
      iosFastInput: false,
      iosPreActionPing: true,
      homeOnStart: true,
      playProtectBypass: true,
      enableAnimations: false,
      reportDir: "",
      updateWebView: true,
      wipeDataOnBloat: true,
      wipeDataThresholdGB: "",
      recoverCpuFallbackToGpu: false,
      locale: "",
      record: true,
      recordFailuresOnly: false,
      recordBitrateKbps: "",
      recordFullResolution: false,
      workspace: "",
    },
  };
}

// OS の包み(.platform-ios / .platform-android)の計算後の display だけを見る(編集欄そのものの
// inline display はデータの読込状態で変わるため)
function isHiddenByScope(window, id) {
  const el = window.document.getElementById(id);
  assert.ok(el, id);
  const wrapper = el.closest(".platform-ios, .platform-android");
  return wrapper !== null && window.getComputedStyle(wrapper).display === "none";
}

function deviceRowNames(window) {
  return [...window.document.querySelectorAll("#run-profile-devices .run-profile-device-row-item .tile-name")]
    .map((el) => el.textContent);
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test("アプリプロファイル: 対象 OS は編集欄の先頭にあり、読み込んだ platform で選んでいない OS の欄を隠す", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(appProfileData("ios"));

  const row = window.document.getElementById("app-profile-platform-row");
  assert.equal(row.parentElement.id, "app-profile-editor");
  assert.equal(row.parentElement.firstElementChild, row);
  assert.equal(window.document.getElementById("app-profile-platform-ios").checked, true);
  assert.equal(isHiddenByScope(window, "app-profile-ios-app-name"), false);
  assert.equal(isHiddenByScope(window, "app-profile-ios-app-path-physical"), false);
  assert.equal(isHiddenByScope(window, "app-profile-android-app-name"), true);
  assert.equal(isHiddenByScope(window, "app-profile-auto-install"), false, "autoInstall は OS に依らない");

  send(appProfileData("hybrid"));
  assert.equal(isHiddenByScope(window, "app-profile-ios-app-name"), false);
  assert.equal(isHiddenByScope(window, "app-profile-android-app-name"), false);
});

test("アプリプロファイル: 対象 OS を変えると platform を自動保存し、隠した OS の欄の値もそのまま送る", (t) => {
  const { window, posted, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(appProfileData("hybrid"));
  posted.length = 0;

  const radio = window.document.getElementById("app-profile-platform-android");
  radio.checked = true;
  radio.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(isHiddenByScope(window, "app-profile-ios-app-name"), true);
  assert.equal(isHiddenByScope(window, "app-profile-android-app-name"), false);
  const save = posted.find((m) => m.type === "appProfileSave");
  assert.ok(save, "対象 OS の変更は保存される");
  assert.equal(save.fields.platform, "android");
  assert.equal(save.fields.autoInstall, "true");
  assert.equal("common" in save.fields, false, "common セクションは廃止");
  assert.deepEqual(plain(save.fields.ios), { appName: "Sample", app: "com.example.ios", appPath: "a.app", appPathPhysical: "" });
});

test("実行プロファイル: アプリが iOS なら iOS セクションとデバイスだけを出し、JSON の Android デバイスは警告で名指しする", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("ios-app", [IOS_SIM, ANDROID_EMU, ANDROID_OFF]));

  assert.equal(isHiddenByScope(window, "run-profile-ios-inapp-engine"), false);
  assert.equal(isHiddenByScope(window, "run-profile-update-webview"), true);
  assert.equal(isHiddenByScope(window, "run-profile-heal"), false, "OS に依らないセクションは出す");
  assert.deepEqual(deviceRowNames(window), ["iPhone 17"]);

  const warning = window.document.getElementById("run-profile-devices-scope-warning");
  assert.notEqual(warning.style.display, "none");
  assert.match(warning.textContent, /ios-app/);
  assert.match(warning.textContent, /Pixel 9/);
  assert.match(warning.textContent, /Pixel 8/, "enabled:false も JSON に居る分は名指しする");
  assert.match(warning.textContent, /2/);
});

test("実行プロファイル: 保存しても対象外 OS のデバイスは JSON から消さない(enabled もそのまま)", (t) => {
  const { window, posted, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("ios-app", [IOS_SIM, ANDROID_EMU, ANDROID_OFF]));
  posted.length = 0;

  const heal = window.document.getElementById("run-profile-heal");
  heal.checked = false;
  heal.dispatchEvent(new window.Event("change", { bubbles: true }));

  const save = posted.find((m) => m.type === "runProfileSave");
  assert.ok(save);
  const devices = plain(save.fields.devices).map((d) => [d.platform, d.name, d.enabled]);
  assert.deepEqual(devices, [
    ["ios", "iPhone 17", true],
    ["android", "Pixel 9", true],
    ["android", "Pixel 8", false],
  ]);
});

test("実行プロファイル: ハイブリッドは両方を出し、警告は出さない", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("both-app", [IOS_SIM, ANDROID_EMU]));

  assert.equal(isHiddenByScope(window, "run-profile-ios-inapp-engine"), false);
  assert.equal(isHiddenByScope(window, "run-profile-update-webview"), false);
  assert.deepEqual(deviceRowNames(window), ["iPhone 17", "Pixel 9"]);
  assert.equal(window.document.getElementById("run-profile-devices-scope-warning").style.display, "none");
});

test("実行プロファイル: アプリを選び直すと、その対象 OS へ絞り直す", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("ios-app", [IOS_SIM, ANDROID_EMU]));

  const app = window.document.getElementById("run-profile-app");
  app.value = "android-app";
  app.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(isHiddenByScope(window, "run-profile-ios-inapp-engine"), true);
  assert.equal(isHiddenByScope(window, "run-profile-update-webview"), false);
  assert.deepEqual(deviceRowNames(window), ["Pixel 9"]);
  assert.match(window.document.getElementById("run-profile-devices-scope-warning").textContent, /iPhone 17/);
});

test("実行プロファイル: アプリ側の対象 OS が変わったら(appProfileFileChanged の appPlatforms で)絞り直す", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("both-app", [IOS_SIM, ANDROID_EMU]));
  assert.deepEqual(deviceRowNames(window), ["iPhone 17", "Pixel 9"]);

  send({ type: "appProfileFileChanged", name: "both-app", appPlatforms: { ...PLATFORMS, "both-app": "ios" } });
  assert.deepEqual(deviceRowNames(window), ["iPhone 17"]);
  assert.equal(isHiddenByScope(window, "run-profile-update-webview"), true);
});

test("実行プロファイル: 絞り込みで作り直しても、未保存のチェック状態を失わない", (t) => {
  const { window, posted, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("both-app", [IOS_SIM, ANDROID_EMU]));

  // 送信中にしておき(保存結果を返さない)、その間に対象 OS だけを変える
  const firstCheckbox = () => window.document.querySelector("#run-profile-devices .run-profile-device-row-item input[type=checkbox]");
  const checkbox = firstCheckbox();
  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  posted.length = 0;
  send(profileInfo({ ...PLATFORMS, "both-app": "ios" }));

  assert.equal(firstCheckbox().checked, false);
});

test("デバイスの追加(既存から選択)は、開いた時点の実行プロファイルの対象 OS の候補だけを出す", (t) => {
  const { window, send } = createWebview(t);
  send(profileInfo(PLATFORMS));
  send(runProfileData("ios-app", [IOS_SIM]));

  window.document.getElementById("btn-run-profile-device-add-existing").click();
  const overlay = window.document.getElementById("device-pick-overlay");
  assert.equal(overlay.dataset.platformScope, "ios");
  assert.equal(window.getComputedStyle(window.document.getElementById("device-pick-android-group")).display, "none");
  assert.notEqual(window.getComputedStyle(window.document.getElementById("device-pick-ios-group")).display, "none");
});
