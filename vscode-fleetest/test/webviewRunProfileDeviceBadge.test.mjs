// webviewRunProfileDeviceBadge.test.mjs
// 実行プロファイルタブのデバイス一覧に、実機だけバッジが出ることを実 HTML+実バンドルで確認する
// DOM E2E(jsdom)。ハーネスの作りは test/webviewRunProfileWorkspace.test.mjs と同じ。
//
// バッジの見た目・文言はマシンプロファイル一覧/タイル/ピッカーと共通(.badge-kind +
// wvMonitor.tile.physicalBadge)。片方だけ変えない。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
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

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return {
    window,
    sendToWebview: (data) => window.dispatchEvent(new window.MessageEvent("message", { data })),
  };
}

const MACHINE_PROFILE_INFO = {
  type: "machineProfileInfo",
  current: "M2Ultra",
  error: null,
  machines: [
    {
      name: "M2Ultra",
      devices: [
        { name: "iPhone 16", platform: "ios", kind: "simulator", detail: "iOS 18.2" },
        { name: "iPhone 実機", platform: "ios", kind: "physical", detail: "iOS 18.2" },
      ],
    },
  ],
};

const PROFILE_INFO = {
  type: "profileInfo",
  profiles: ["ios-1"],
  current: "ios-1",
  filter: "all",
  apps: ["sut-ec-mobile"],
  project: "sut-ec-mobile",
};

const RUN_PROFILE_DATA = {
  type: "runProfileData",
  profile: "ios-1",
  ok: true,
  error: null,
  fields: { machine: "M2Ultra", app: "sut-ec-mobile", devices: [] },
};

function deviceRows(window) {
  return [...window.document.getElementById("run-profile-devices").querySelectorAll(".run-profile-device-row")];
}

test("実行プロファイルのデバイス一覧は実機にだけバッジを出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(MACHINE_PROFILE_INFO);
  sendToWebview(PROFILE_INFO);
  // 一覧はフォームのマシンが決まってから描かれる(未選択の間は案内文だけ)
  sendToWebview(RUN_PROFILE_DATA);

  const rows = deviceRows(window);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].querySelector(".badge-kind"), null, "仮想デバイスにはバッジを出さない");
  const badge = rows[1].querySelector(".badge-kind");
  assert.ok(badge, "実機にはバッジを出す");
  assert.equal(badge.textContent, "実機");
  // バッジはデバイス名ピルの左(マシンプロファイル一覧と同じ並び)
  assert.equal(badge.nextElementSibling, rows[1].querySelector(".tile-name"));
});

test("マシンに無い名前(欠落)にはバッジを出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(MACHINE_PROFILE_INFO);
  sendToWebview(PROFILE_INFO);
  sendToWebview({
    ...RUN_PROFILE_DATA,
    fields: { ...RUN_PROFILE_DATA.fields, devices: [{ name: "iPhone 実機" }, { name: "消えた台" }] },
  });

  const rows = deviceRows(window);
  const missing = rows.find((row) => row.querySelector(".tile-name").textContent === "消えた台");
  assert.ok(missing, "チェック済みで欠落した名前も行としては出る");
  assert.equal(missing.querySelector(".badge-kind"), null, "種別が分からない行にバッジは出さない");
  const physical = rows.find((row) => row.querySelector(".tile-name").textContent === "iPhone 実機");
  assert.ok(physical.querySelector(".badge-kind"), "実機のバッジは runProfileData 適用後も出る");
});
