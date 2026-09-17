// フリートのタイルの右クリックメニューの「このデバイスのみ選択」の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewGpuRestartCarriesMachine.test.mjs と同じ。

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

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const sent = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => sent.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, sent };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 手元の Simulator 2 台。devices の同期でタイルが2枚できる */
function sendDevices(window) {
  post(window, {
    type: "devices",
    devices: ["Sim 1", "Sim 2"].map((name) => ({
      id: `ios:${name}`, name, platform: "ios", state: "connected", kind: "virtual", udid: name, recording: false,
    })),
  });
}

function rightClick(window, el) {
  el.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
}

function click(window, el) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
}

function selectedNames(document) {
  return [...document.querySelectorAll("#grid .tile.selected .tile-name")].map((el) => el.textContent);
}

test("タイルの右クリックの「このデバイスのみ選択」は「すべて選択」の直前に並び、その台だけの選択に置き換える", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  const [first, second] = document.querySelectorAll("#grid .tile");
  const only = document.getElementById("device-op-menu-select-only");
  assert.equal(only.nextElementSibling, document.getElementById("device-op-menu-select-all"));
  assert.equal(only.textContent, "このデバイスのみ選択");

  rightClick(window, first);
  click(window, document.getElementById("device-op-menu-select-all"));
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 2);
  sent.length = 0;

  rightClick(window, second);
  assert.notEqual(only.style.display, "none");
  assert.equal(only.disabled, false);
  click(window, only);
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 1);
  assert.ok(second.classList.contains("selected"), "右クリックした台が残る");
  assert.ok(!document.getElementById("device-op-menu").classList.contains("visible"), "押したら閉じる");
  assert.deepStrictEqual(JSON.parse(JSON.stringify(sent.filter((m) => m.type === "setSelectAllDevices"))),
    [{ type: "setSelectAllDevices", value: false }], "全選択の旗は落ちる");

  rightClick(window, second);
  assert.equal(only.disabled, true, "既にその台だけなら押せない");
  rightClick(window, first);
  assert.equal(only.disabled, false, "別の台からは押せる");
});

test("空きエリアの右クリックでは「このデバイスのみ選択」を出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  rightClick(window, document.getElementById("grid"));
  assert.ok(document.getElementById("device-op-menu").classList.contains("visible"));
  assert.equal(document.getElementById("device-op-menu-select-only").style.display, "none");
});
