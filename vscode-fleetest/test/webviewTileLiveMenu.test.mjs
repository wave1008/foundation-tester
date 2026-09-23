// デバイスタイルの右クリックメニューに「ライブ操作」を出す条件の DOM E2E(jsdom)。
// harness は webviewTileMenuTarget.test.mjs と同型。
//
// 実地 2026-09-24: iPhone wave(実機)は Wi-Fi 越しに M1Ultra からも見えるので、モニターに
// 「この Mac の iPhone wave」(booted = ブリッジ未起動)と「M1Ultra の iPhone wave」の2枚が並ぶ。
// どちらのタイルからでも開けるようにする: connected か **iOS の booted**(開けばブリッジを自動起動する)。
// **他の機械の台は serve をその機械で起こす**ので、開くのに要る属性(machine・udid 等)を
// openLiveForDevice の remote で運ぶ(この Mac の list-devices には居ない)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
let panelHtml, webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")], bundle: true, platform: "node",
    format: "cjs", target: "node18", write: false, external: ["vscode"], logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(
    mod, mod.exports, (id) => (id === "vscode" ? vscodeStub : require2(id)));
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" }, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")], bundle: true, platform: "browser",
    format: "iife", target: "es2022", write: false, logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview() {
  const posted = [];
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message), setState: () => {}, getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.dispatchEvent(new window.MessageEvent("message", {
    data: {
      type: "devices",
      devices: DEVICES,
    },
  }));
  return { window, document: window.document, posted };
}

function tiles(document) {
  return [...document.querySelectorAll("#grid .tile")];
}

function rightClick(window, el) {
  el.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
}


const DEVICES = [
  { id: "ios:Local Connected", name: "Local Connected", platform: "ios", state: "connected", kind: "physical", udid: "A", recording: false },
  { id: "ios:Local Booted", name: "Local Booted", platform: "ios", state: "booted", kind: "physical", udid: "B", recording: false },
  { id: "ios:M1Ultra/Remote", name: "Remote", platform: "ios", state: "connected", kind: "physical", udid: "C", machine: "M1Ultra", recording: false },
  { id: "ios:M1Ultra/Unobserved", name: "Unobserved", platform: "ios", state: "unknown", kind: "physical", machine: "M1Ultra", recording: false },
  { id: "android:Booted Emu", name: "Booted Emu", platform: "android", state: "booted", kind: "virtual", serial: "emulator-5554", recording: false },
  { id: "ios:Local Offline", name: "Local Offline", platform: "ios", state: "offline", kind: "virtual", recording: false },
];

function liveShown(window, document, name) {
  const tile = tiles(document).find((el) => el.querySelector(".tile-name")?.textContent.includes(name));
  assert.ok(tile, `前提: ${name} のタイルがある`);
  rightClick(window, tile);
  return document.getElementById("device-op-menu-live").style.display !== "none";
}

test("「ライブ操作」は connected と iOS の booted に出す(他の機械の台も)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  assert.equal(liveShown(window, document, "Local Connected"), true, "この Mac の connected");
  assert.equal(liveShown(window, document, "Local Booted"), true, "この Mac の iOS の booted(開けば自動起動する)");
  assert.equal(liveShown(window, document, "Remote"), true, "他の機械の connected にも出す(serve をその機械で起こす)");
  assert.equal(liveShown(window, document, "Unobserved"), false, "観測できていない台(unknown)には出さない");
  assert.equal(liveShown(window, document, "Booted Emu"), false, "Android の booted は自動起動が無いので出さない");
  assert.equal(liveShown(window, document, "Local Offline"), false, "offline は出さない");
});

test("他の機械の台を開くときは remote で machine・udid を運び、この Mac の台では運ばない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());

  assert.equal(liveShown(window, document, "Remote"), true);
  document.getElementById("device-op-menu-live").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  // jsdom のオブジェクトは別レルムなので JSON で畳んでから比べる
  const lastOpen = () => JSON.parse(JSON.stringify(posted.filter((m) => m.type === "openLiveForDevice").at(-1)));
  const remoteOpen = lastOpen();
  assert.deepEqual(remoteOpen, {
    type: "openLiveForDevice", id: "ios:M1Ultra/Remote",
    remote: { machine: "M1Ultra", name: "Remote", platform: "ios", state: "connected", kind: "physical", udid: "C" },
  });

  assert.equal(liveShown(window, document, "Local Connected"), true);
  document.getElementById("device-op-menu-live").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const localOpen = lastOpen();
  assert.deepEqual(localOpen, { type: "openLiveForDevice", id: "ios:Local Connected" }, "この Mac の台は id だけ");
});
