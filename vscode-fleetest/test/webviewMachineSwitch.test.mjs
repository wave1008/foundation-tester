// webviewMachineSwitch.test.mjs
// マシンプロファイルタブ(machineProfilesTab.js)のマシン切替(select の change / ホストからの
// machineProfileSelected)の DOM テスト。実 HTML+実バンドルで動かす方式は
// webviewMachineDeviceMachineScope.test.mjs と同じ。
//
// 切替時の選択キー検証が存在しない関数名(validateSelectedDeviceName)を呼んで ReferenceError で
// 止まり、デバイス一覧が前のマシンのまま残っていた。jsdom はリスナ内の例外を dispatchEvent の
// 呼び手へ投げない(window の error として報告する)ので、一覧の中身と error イベントの両方で見る。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
const TAB_SOURCE = path.resolve("src/webview/monitor/machineProfilesTab.js");

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

function createWebview() {
  const errors = [];
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.addEventListener("error", (event) => errors.push(String(event.error ?? event.message)));
  window.eval(webviewBundle);
  return { window, document: window.document, errors };
}

const MACHINES = [
  {
    name: "M1",
    devices: [{ name: "シミュA", platform: "ios", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "UA" }],
  },
  {
    name: "M2",
    devices: [{ name: "シミュB", platform: "ios", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "UB" }],
  },
];

function postMachines(window, current) {
  window.dispatchEvent(
    new window.MessageEvent("message", {
      data: { type: "machineProfileInfo", machines: MACHINES, current, error: null },
    }),
  );
}

function deviceNames(document) {
  return [...document.querySelectorAll("#machine-device-list .machine-device-row")]
    .map((row) => row.textContent)
    .map((text) => (text.includes("シミュA") ? "シミュA" : text.includes("シミュB") ? "シミュB" : text));
}

test("select でマシンを切り替えると、そのマシンのデバイス一覧に変わる", (t) => {
  const { window, document, errors } = createWebview();
  t.after(() => window.close());

  postMachines(window, "M1");
  assert.deepEqual(deviceNames(document), ["シミュA"]);

  const select = document.getElementById("machine-select");
  select.value = "M2";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.deepEqual(errors, [], "切替のリスナが例外で止まっている");
  assert.deepEqual(deviceNames(document), ["シミュB"]);
});

test("ホストの machineProfileSelected でも一覧が切り替わる", (t) => {
  const { window, document, errors } = createWebview();
  t.after(() => window.close());

  postMachines(window, "M1");
  window.dispatchEvent(
    new window.MessageEvent("message", { data: { type: "machineProfileSelected", name: "M2" } }),
  );

  assert.deepEqual(errors, [], "選択移動のリスナが例外で止まっている");
  assert.deepEqual(deviceNames(document), ["シミュB"]);
  assert.equal(document.getElementById("machine-select").value, "M2");
});

test("ソース走査: validateSelected* の呼び出しは同ファイルで定義された関数だけを指す", () => {
  const source = fs.readFileSync(TAB_SOURCE, "utf8");
  const defined = new Set([...source.matchAll(/function\s+(validateSelected\w*)\s*\(/g)].map((m) => m[1]));
  const called = [...source.matchAll(/(?<!function\s)\b(validateSelected\w*)\s*\(/g)].map((m) => m[1]);
  assert.ok(called.length > 0);
  for (const name of called) {
    assert.ok(defined.has(name), `${name} は machineProfilesTab.js に定義が無い`);
  }
});
