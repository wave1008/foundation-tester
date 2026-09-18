// webviewRunProfileDeviceMachine.test.mjs
// 実行プロファイルのデバイス参照が **(platform, machine, name)** で往復することの DOM E2E(jsdom)。
// ハーネスの作りは webviewRunProfileDeviceBadge.test.mjs と同じ。
//
// **この経路が壊れると利用者のプロファイルが黙って書き換わる**(2026-08-26 の実害): webview が
// 参照の機械を読めないと、リモートの台の参照が同名の手元の行にチェックされ、確定した時点で
// devices[].machine が省略(手元)で保存される。読み(runProfileData)と書き(runProfileSave)の
// 両方を1本で縛る。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";

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

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return {
    window,
    sendToWebview: (data) => window.dispatchEvent(new window.MessageEvent("message", { data })),
  };
}

// 手元と M1Max に同名 "iPhone 16" が居る形(各機が同じ命名規則で作るので通常。
// プロジェクトのデバイスカタログ = 全実行プロファイルの devices[] の和集合)。
const PROFILE_INFO = {
  type: "profileInfo",
  projects: ["sut-ec-mobile"],
  profiles: ["all"],
  current: "all",
  filter: "all",
  apps: ["sut-ec-mobile"],
  project: "sut-ec-mobile",
  projectDir: "TestProjects/sut-ec-mobile",
  devices: [
    { platform: "ios", name: "iPhone 16", detail: "iOS 18.2" },
    { platform: "ios", name: "iPhone 16", machine: "M1Max", detail: "iOS 18.2" },
  ],
};

// このプロファイル自身が持つのは M1Max の参照だけ(手元の同名はカタログにしか居ない)。
const RUN_PROFILE_DATA = {
  type: "runProfileData",
  profile: "all",
  ok: true,
  error: null,
  // 数値・文字列の欄は **省略しない** —— undefined を入力欄へ入れると "undefined" になり、
  // 保存前の入力検証で弾かれて runProfileSave まで到達しない(拡張は常に全欄を送る)。
  fields: {
    app: "sut-ec-mobile",
    devices: [{ platform: "ios", name: "iPhone 16", machine: "M1Max", enabled: true }],
    heal: true,
    textVisualCheck: true,
    screenLooksLike: true,
    ocrTextVisualCheck: true,
    preferCheckStateClassifier: true,
    iosInappEngine: true,
    iosFastInput: false,
    iosPreActionWarmup: true,
    homeOnStart: true,
    playProtectBypass: true,
    enableAnimations: false,
    containerInference: true,
    updateWebView: true,
    wipeDataOnBloat: true,
    recoverCpuFallbackToGpu: false,
    record: false,
    recordFailuresOnly: false,
    recordBitrateKbps: "",
    recordFullResolution: false,
    wipeDataThresholdGB: "",
    locale: "",
    workspace: "",
    reportDir: "",
  },
};

function deviceRows(window) {
  return [...window.document.getElementById("run-profile-devices").querySelectorAll(".run-profile-device-row-item")];
}

test("リモートの台の参照は、その機械の行だけにチェックが入る(手元の同名を巻き込まない)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(PROFILE_INFO);
  sendToWebview(RUN_PROFILE_DATA);

  const rows = deviceRows(window);
  assert.equal(rows.length, 2, "同名でも機械が違えば別の行");
  const checkedOf = (row) => row.querySelector('input[type="checkbox"]').checked;
  const badgeOf = (row) => row.querySelector(".badge-remote")?.textContent;
  const remote = rows.find((row) => badgeOf(row) === "M1Max");
  const local = rows.find((row) => badgeOf(row) === undefined);
  assert.ok(remote && local, "M1Max のバッジが付く行と手元の行が1つずつ");
  assert.equal(checkedOf(remote), true, "参照が指しているのは M1Max の台");
  assert.equal(checkedOf(local), false, "手元の同名を巻き込んでいる");
});

test("自動保存は machine 付きの参照で保存し、拡張側のゲートを通る", (t) => {
  const posted = [];
  const { window, sendToWebview } = createWebview((message) => posted.push(message));
  t.after(() => window.close());
  sendToWebview(PROFILE_INFO);
  sendToWebview(RUN_PROFILE_DATA);

  // デバイス以外の欄だけ変えて保存する = 読んだ参照をそのまま書き戻す(実害が出たのはこの経路)。
  window.document.getElementById("run-profile-heal").click();

  const raw = posted.filter((m) => m.type === "runProfileSave").at(-1);
  assert.ok(raw, `runProfileSave が送られる (error=${window.document.getElementById("run-profile-error").textContent} posted=${posted.map((m) => m.type).join(",")})`);
  // realm 違いの deepStrictEqual を避けるため postMessage と同じく構造化して比べる。
  const message = JSON.parse(JSON.stringify(raw));
  assert.deepEqual(message.fields.devices, [{ platform: "ios", name: "iPhone 16", machine: "M1Max", enabled: true }]);
  assert.equal(isMonitorFromWebviewMessage(message), true);
});
