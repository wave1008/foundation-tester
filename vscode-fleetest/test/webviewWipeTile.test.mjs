// Wipe Data 実行中のタイル表示の DOM テスト(deviceTiles.js の renderFrame/renderMeta)。
//
// 背景(2026-08-29 の報告): リモートの台を Wipe Data すると、タイルは**消える前の画面のまま**
// 固まって見えた。down と違って状態が offline へ倒れるとは限らない(止めずに終わる台もある)し、
// 実行中はモニターを pause しているので新しい観測も来ない —— つまり放っておくと
// 「押したのに何も起きていない」ようにしか見えない。
//
// 守る規律3つ:
//  - 実行中は**最後のフレームを出さない**(消した/作り直している最中の中身を映さない)
//  - フェーズ(停止中 → 再起動中)を出す = 進捗が分かる
//  - 宛先は (name, machine)。**同名の手元のタイルを巻き込まない**
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewRemoteTilePlaceholder.test.mjs と同じ。

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

/** 手元と M1Ultra に同名の台。どちらも connected でフレームが載っている状態にする */
function sendConnectedPairWithFrames(window) {
  post(window, {
    type: "devices",
    devices: [
      {
        id: "android:Emu 1", name: "Emu 1", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5554", recording: false,
      },
      {
        id: "android:M1Ultra/Emu 1", name: "Emu 1", platform: "android", state: "connected",
        kind: "virtual", serial: "emulator-5554", recording: false, machine: "M1Ultra",
      },
    ],
  });
  for (const device of ["android:Emu 1", "android:M1Ultra/Emu 1"]) {
    post(window, { type: "frame", device, jpegBase64: "AAAA", width: 100, height: 200 });
  }
}

function tiles(document) {
  return [...document.querySelectorAll("#grid .tile")];
}

/** そのタイルが画像を出しているか(出していなければプレースホルダ) */
function showsImage(tile) {
  return tile.querySelector(".frame-wrap img") !== null;
}

function placeholderText(tile) {
  return tile.querySelector(".frame-placeholder")?.textContent ?? "";
}

test("wipe 実行中のタイルは最後のフレームを出さず、フェーズを出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendConnectedPairWithFrames(window);

  const [local, remote] = tiles(document);
  assert.equal(showsImage(remote), true, "前提: 開始前はライブ映像が出ている");

  post(window, { type: "deviceOpBusy", name: "Emu 1", machine: "M1Ultra", op: "wipe", status: "running" });
  post(window, { type: "wipeStatus", name: "Emu 1", machine: "M1Ultra", phase: "stopping" });
  assert.equal(showsImage(remote), false, "消える前の画面を映し続けてはいけない");
  assert.match(placeholderText(remote), /停止中/);

  post(window, { type: "wipeStatus", name: "Emu 1", machine: "M1Ultra", phase: "rebooting" });
  assert.match(placeholderText(remote), /再起動中/, "フェーズが進んだことが見える");

  assert.equal(showsImage(local), true, "同名の手元のタイルは巻き込まない");
});

test("wipe が終わればフレーム表示に戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendConnectedPairWithFrames(window);
  const remote = tiles(document)[1];

  post(window, { type: "deviceOpBusy", name: "Emu 1", machine: "M1Ultra", op: "wipe", status: "running" });
  post(window, { type: "wipeStatus", name: "Emu 1", machine: "M1Ultra", phase: "stopping" });
  assert.equal(showsImage(remote), false);

  post(window, { type: "wipeStatus", name: "Emu 1", machine: "M1Ultra", phase: "done" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", machine: "M1Ultra", op: null, status: null });
  post(window, { type: "frame", device: "android:M1Ultra/Emu 1", jpegBase64: "BBBB", width: 100, height: 200 });
  assert.equal(showsImage(remote), true, "終わったら新しい映像に戻る");
});

test("wipe のキュー待ちは映像を消さない(まだ何も起きていない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendConnectedPairWithFrames(window);
  const remote = tiles(document)[1];

  post(window, { type: "deviceOpBusy", name: "Emu 1", machine: "M1Ultra", op: "wipe", status: "queued" });
  assert.equal(showsImage(remote), true, "順番待ちの間はまだ動いている台なので映像を残す");
});
