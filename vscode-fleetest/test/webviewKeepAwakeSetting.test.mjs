// 設定タブ「実機」→「実機画面の自動ロックを抑制する」の往復。実 HTML + 実バンドルで動かす
// (方式は webviewRemoteHostsSettings.test.mjs と同じ)。
//
// **型の効かない境界**なので両側を1本で縛る: webview が送るメッセージ名が拡張側のゲート
// (isMonitorFromWebviewMessage)と食い違うと、チェックを外しても捨てられ、
// 画面上は外れているのに実機は起こされ続ける(気付けるのは実機を放置したときだけ)。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
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

test("チェックボックスは「デバイス画面」セクションの下の「実機」セクションにある", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const groups = [...document.querySelectorAll("#panel-settings .settings-group")];
  const deviceScreenIndex = groups.findIndex((g) => g.querySelector("#settings-polling-mode"));
  const physicalIndex = groups.findIndex((g) => g.querySelector("#settings-keep-awake"));
  assert.ok(physicalIndex >= 0, "実機セクションのチェックボックスが無い");
  assert.equal(physicalIndex, deviceScreenIndex + 1,
    "実機セクションはデバイス画面セクションの直下に置く");
});

test("拡張から届いた値がチェック状態に入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "keepPhysicalDevicesAwake", value: false });
  assert.equal(document.getElementById("settings-keep-awake").checked, false);
  post(window, { type: "keepPhysicalDevicesAwake", value: true });
  assert.equal(document.getElementById("settings-keep-awake").checked, true);
});

test("チェックを外すと setKeepPhysicalDevicesAwake:false が送られ、拡張側のゲートを通る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, { type: "keepPhysicalDevicesAwake", value: true });
  const checkbox = document.getElementById("settings-keep-awake");
  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  const raw = posted.filter((m) => m.type === "setKeepPhysicalDevicesAwake").at(-1);
  assert.ok(raw, "setKeepPhysicalDevicesAwake が送られる");
  const message = JSON.parse(JSON.stringify(raw));
  assert.deepEqual(message, { type: "setKeepPhysicalDevicesAwake", value: false });
  assert.ok(isMonitorFromWebviewMessage(message),
    "拡張側のゲートに弾かれる(名前か値の形が食い違っている)");
});
