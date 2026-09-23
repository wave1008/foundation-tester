// デバイスタイルを右クリックしている間だけ、そのタイルに対象の印(.menu-target)を付けることの
// DOM E2E(jsdom)。harness は webviewTileStreamStalePoll.test.mjs と同型。
//
// ユーザー決定(2026-09-23): 右クリックしたデバイスが分かるようにする / メニューの項目を選んだとき・
// メニューを閉じたときは解く / **エフェクトはメニューを出している間だけ**(チェックボックスの
// 永続的な選択 .selected とは別の印)。

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
      devices: [
        { id: "android:Emu 1", name: "Emu 1", platform: "android", state: "connected", kind: "virtual", serial: "emulator-5554", recording: false },
        { id: "android:Emu 2", name: "Emu 2", platform: "android", state: "connected", kind: "virtual", serial: "emulator-5556", recording: false },
      ],
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

function marked(document) {
  return tiles(document).filter((tile) => tile.classList.contains("menu-target"));
}

test("右クリックしたタイルにだけ印が付く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const [first, second] = tiles(document);
  assert.equal(marked(document).length, 0, "前提: 何も付いていない");

  rightClick(window, first);
  assert.deepEqual(marked(document), [first], "右クリックしたタイルだけに付くこと");

  // 別のタイルを右クリックしたら印も移る(前のタイルに残さない)
  rightClick(window, second);
  assert.deepEqual(marked(document), [second], "印は1台ぶんだけ残ること");
});

test("メニューを閉じたら印を解く(Escape)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  rightClick(window, tiles(document)[0]);
  assert.equal(marked(document).length, 1, "前提: 付いている");

  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(marked(document).length, 0, "閉じたら解くこと");
});

test("メニューの項目を選んだら印を解く", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());

  rightClick(window, tiles(document)[0]);
  assert.equal(marked(document).length, 1, "前提: 付いている");

  document.getElementById("device-op-menu-live").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  assert.ok(posted.some((m) => m.type === "openLiveForDevice"), "前提: 項目が効いている");
  assert.equal(marked(document).length, 0, "項目を選んだら解くこと");
});

test("空きエリアの右クリックはどのタイルにも印を付けない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  rightClick(window, tiles(document)[0]);
  assert.equal(marked(document).length, 1, "前提: 付いている");

  rightClick(window, document.getElementById("grid"));
  assert.equal(marked(document).length, 0, "対象のデバイスが無いメニューでは印を残さないこと");
});

function previews(document) {
  return [...document.querySelectorAll("#preview-grid .lane-preview")].filter((el) => el.style.display !== "none");
}

// 選択した台は グリッドビューにも拡大表示(.lane-preview)が出る。どちらを右クリックしても
// 同じデバイスのメニューなので、印も両方に付ける。
test("選択した台はタイルと拡大表示の両方に印が付く(どちらを右クリックしても)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const [first] = tiles(document);
  // jsdom は矩形が 0 でクリックの当たり判定が効かないので、メニューの「このデバイスのみ選択」で選ぶ
  rightClick(window, first);
  document.getElementById("device-op-menu-select-only").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const [preview] = previews(document);
  assert.ok(preview, "前提: 選択した台の拡大表示が出ている");
  assert.equal(preview.classList.contains("menu-target"), false, "前提: 付いていない");

  rightClick(window, first);
  assert.deepEqual(marked(document), [first], "タイルに付くこと");
  assert.ok(preview.classList.contains("menu-target"), "タイルの右クリックで拡大表示にも付くこと");

  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(preview.classList.contains("menu-target"), false, "閉じたら拡大表示からも解くこと");

  rightClick(window, preview);
  assert.deepEqual(marked(document), [first], "拡大表示の右クリックでタイルにも付くこと");
  assert.ok(preview.classList.contains("menu-target"), "拡大表示に付くこと");

  rightClick(window, tiles(document)[1]);
  assert.equal(preview.classList.contains("menu-target"), false, "別の台へ移ったら拡大表示から解くこと");
});
