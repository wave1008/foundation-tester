// Android 実機の「ブリッジ未起動」表示の DOM テスト(deviceTiles.js の bridgeNotRunning/renderFrame)。
//
// iOS 実機は state==="booted" だけでブリッジ不在を表せるが、Android の state は
// 「adb に見えるか」「ブート完了か」しか表さないため、専用の欄 device.bridgeRunning
// (ApiMonitorCommand.shouldProbeBridge が Android 実機の connected だけに設定)で見る
// (ユーザー決定: 案A — iOS 実機に揃える)。
//
// 守る3分岐: bridgeRunning===false は未起動として絵を出さない / bridgeRunning===true は
// 通常どおり絵を出す / **undefined(不明。欠落・観測不能)は false に丸めず絵を出す**
// (丸めると pidof が一時的に失敗しただけの回に生きているブリッジの絵が消える)。
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewWipeTile.test.mjs と同じ。

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

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

const deviceId = "android:Pixel 実機";

/** Android 実機1台を connected で送る(bridgeRunning は呼び出し側が指定)。 */
function sendPhysicalAndroid(window, bridgeRunning) {
  const device = {
    id: deviceId, name: "Pixel 実機", platform: "android", state: "connected", kind: "physical",
    serial: "14141JEC204922", recording: false,
  };
  if (bridgeRunning !== undefined) {
    device.bridgeRunning = bridgeRunning;
  }
  post(window, { type: "devices", devices: [device] });
}

function sendFrame(window) {
  post(window, { type: "frame", device: deviceId, jpegBase64: "AAAA", width: 100, height: 200 });
}

function tile(document) {
  return document.querySelector("#grid .tile");
}

function showsImage(document) {
  return tile(document).querySelector(".frame-wrap img") !== null;
}

function placeholderText(document) {
  return tile(document).querySelector(".frame-placeholder")?.textContent ?? "";
}

test("bridgeRunning===false: 絵を出さず「ブリッジ未起動」を表示する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, false);
  sendFrame(window);

  assert.equal(showsImage(document), false, "ブリッジ未起動が確定した台に絵を出さないこと");
  assert.match(placeholderText(document), /ブリッジ未起動/);
});

test("bridgeRunning===true: 通常どおり絵を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  sendFrame(window);

  assert.equal(showsImage(document), true);
});

test("bridgeRunning が未設定(不明): false に丸めず絵を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, undefined);
  sendFrame(window);

  assert.equal(showsImage(document), true,
    "観測できないだけの回に生きているブリッジの絵を消してはいけない");
});
