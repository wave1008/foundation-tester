// ライブ操作タブでデバイスを切り替えたとき、**前の台の画面を出し続けない**ことの DOM E2E(jsdom)。
// harness とフェイク(getContext / VideoDecoder / EncodedVideoChunk)は
// webviewLiveSnapshotKeepsH264.test.mjs と同型。ただし VideoDecoder は **decode しても即 output せず、
// flush() を呼ぶまで溜める** —— 実物のデコードは非同期なので、切り替えの瞬間にも前の台のフレームが
// デコード待ちで残っている。close() 後は実物と同じく output しない。
//
// 実害(2026-09-24): Android の実機を見た後、タイル右クリックで iOS 実機の「ライブ操作」を選ぶと、
// 画面が Android のまま変わらなかった。host の clearSnapshot で絵は捨てていたが、デコーダを
// 残していたため、デコード待ちだった Android のフレームが描けた時点で onFrameRendered が
// canvas を前面へ戻していた(iOS 実機は simstream を使えず新しい絵が来るまで時間がかかるので、
// その間ずっと前の台の画面が出ていた)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
let panelHtml, webviewBundle;

const KEYFRAME = new Uint8Array([0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 1, 0x65, 0x88]);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true, platform: "node", format: "cjs", target: "node18",
    write: false, external: ["vscode"], logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" }, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true, platform: "browser", format: "iife", target: "es2022",
    write: false, logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posts.push(message), setState: () => {}, getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.HTMLCanvasElement.prototype.getContext = () => ({ drawImage() {} });
  const decoders = [];
  window.VideoDecoder = class {
    static isConfigSupported() { return Promise.resolve({ supported: true }); }
    constructor({ output }) { this.output = output; this.pending = 0; this.closed = false; decoders.push(this); }
    configure() {}
    decode() { this.pending += 1; }
    close() { this.closed = true; }
    flush() {
      while (this.pending > 0 && !this.closed) {
        this.pending -= 1;
        this.output({ displayWidth: 400, displayHeight: 800, close() { this.displayWidth = 0; this.displayHeight = 0; } });
      }
    }
  };
  window.EncodedVideoChunk = class { constructor(init) { Object.assign(this, init); } };
  window.eval(webviewBundle);
  window.document.getElementById("tab-live").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const flushAll = () => { for (const d of decoders) { d.flush(); } };
  return { window, document: window.document, posts, flushAll };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function media(document) {
  return {
    canvas: document.getElementById("live-canvas"),
    screenshot: document.getElementById("live-screenshot"),
  };
}

function sendDevices(window, selectedId) {
  post(window, {
    type: "live",
    message: {
      type: "devices",
      devices: [
        { id: "android:Pixel", name: "Pixel", platform: "android", state: "connected" },
        { id: "ios:iPhone", name: "iPhone", platform: "ios", state: "booted" },
      ],
      selectedId,
    },
  });
}

// 前の台(Android)の配信が h264 で canvas に出ている状態を作る
async function showAndroidStream(window, document, flushAll) {
  sendDevices(window, "android:Pixel");
  post(window, { type: "liveH264Chunk", keyframe: true, width: 0, height: 0, data: KEYFRAME });
  await settle();
  flushAll();
  assert.ok(media(document).canvas.classList.contains("visible"), "前提: 前の台の配信が canvas に出ている");
}

test("host が台を切り替えた(clearSnapshot)あとに、前の台のデコード待ちフレームで canvas を前面へ戻さない", async (t) => {
  const { window, document, flushAll } = createWebview();
  t.after(() => window.close());
  await showAndroidStream(window, document, flushAll);

  // 描画間引き(DRAW_INTERVAL_MS=66ms)を跨がせる = 溜めたフレームが本当に描かれる条件にする
  const base = window.performance.now();
  window.performance.now = () => base + 1000;
  // 切り替えの直前に届いた前の台のデルタ(デコード待ちのまま残る)
  post(window, { type: "liveH264Chunk", keyframe: false, width: 0, height: 0, data: KEYFRAME });
  await settle();

  post(window, { type: "live", message: { type: "clearSnapshot" } });
  flushAll();

  const after = media(document);
  assert.ok(!after.canvas.classList.contains("visible"), "前の台の絵を前面に戻さないこと");
  assert.ok(!after.screenshot.classList.contains("visible"), "静止画も出さない(placeholder のまま)");
  assert.notEqual(document.getElementById("live-screenshot-placeholder").style.display, "none",
    "新しい台の絵が来るまで placeholder を出すこと");
});

test("タイル右クリックの「ライブ操作」で別の台を開いた時点で、前の台の静止画を出さない", async (t) => {
  const { window, document, posts, flushAll } = createWebview();
  t.after(() => window.close());
  await showAndroidStream(window, document, flushAll);
  // 前の台の一枚絵(操作結果の snapshot)も持っている状態
  post(window, {
    type: "live",
    message: { type: "snapshot", screen: { width: 400, height: 800 }, image: "ANDROID", elements: [] },
  });
  assert.ok(media(document).screenshot.getAttribute("src"), "前提: 前の台の一枚絵がある");

  post(window, { type: "liveOpenDevice", id: "ios:iPhone" });

  const after = media(document);
  assert.equal(after.screenshot.getAttribute("src"), null, "前の台の一枚絵を捨てること");
  assert.ok(!after.screenshot.classList.contains("visible"), "静止画を前面に出さないこと");
  assert.ok(!after.canvas.classList.contains("visible"), "前の台の配信も出さないこと");
  assert.ok(posts.some((m) => m.type === "live" && m.message.type === "openDevice" && m.message.id === "ios:iPhone"),
    "前提: host へ開く台を伝えている");
});

test("同じ台を開き直すときは今の絵を捨てない", async (t) => {
  const { window, document, flushAll } = createWebview();
  t.after(() => window.close());
  await showAndroidStream(window, document, flushAll);
  post(window, {
    type: "live",
    message: { type: "snapshot", screen: { width: 400, height: 800 }, image: "ANDROID", elements: [] },
  });

  post(window, { type: "liveOpenDevice", id: "android:Pixel" });

  assert.ok(media(document).screenshot.getAttribute("src"), "同じ台なら絵を残すこと(空白を挟まない)");
});
