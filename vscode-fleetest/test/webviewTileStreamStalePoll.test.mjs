// タイルの h264 配信中に「定期ポーリングの安全弁フレーム」(stream 無し。
// monitorDeviceStreamController.ts 冒頭コメント「受信後の安全弁として残る」)が1枚遅れて届いても、
// canvas(h264)表示を静止画へ戻さないことの回帰テスト。
//
// 実害(docs/bug-audit-2026-09-06.md §3 deviceTiles.js:1087): applyFrame が entry.usingH264 の間
// 無条件に disposeH264 していたため、この安全弁フレームが届くたびに h264 デコーダを作り直すことになり、
// 次のキーフレーム到達まで表示が止まっていた。真の mjpeg フォールバック復帰(stream:true。
// mjpeg ストリーミングヘルパー由来)のときだけ破棄してよい。
//
// jsdom には 2D canvas コンテキストが無い(canvas パッケージ未導入。deviceTiles.js の
// copyMirrorFrame 冒頭コメント参照)ため、HTMLCanvasElement.prototype.getContext と
// VideoDecoder/EncodedVideoChunk をテスト用に差し替える(h264Decoder.test.mjs と同型のフェイク)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
let panelHtml, webviewBundle;

// 先頭付近に SPS(NAL type 7)がある Annex-B(h264Decoder.test.mjs と同じ固定チャンク)。
const KEYFRAME = new Uint8Array([0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 1, 0x65, 0x88]);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

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
  // jsdom の canvas には 2D コンテキストが無い(実描画はしないダミーで足りる)。
  window.HTMLCanvasElement.prototype.getContext = () => ({ drawImage() {} });
  // VideoDecoder は decode() 呼び出しで即 1 フレームを output する最小フェイク。
  window.VideoDecoder = class {
    static isConfigSupported() { return Promise.resolve({ supported: true }); }
    constructor({ output }) { this.output = output; }
    configure() {}
    decode() {
      const frame = {
        displayWidth: 400, displayHeight: 800,
        close() { this.displayWidth = 0; this.displayHeight = 0; },
      };
      this.output(frame);
    }
    close() {}
  };
  window.EncodedVideoChunk = class {
    constructor(init) { Object.assign(this, init); }
  };
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function sendDevices(window) {
  post(window, {
    type: "devices",
    devices: [{
      id: "android:Emu 1", name: "Emu 1", platform: "android", state: "connected", kind: "virtual",
      serial: "emulator-5554", recording: false,
    }],
  });
}

async function sendKeyframeAndAwaitH264(window) {
  post(window, { type: "h264Chunk", device: "android:Emu 1", keyframe: true, width: 0, height: 0, data: KEYFRAME });
  await settle();
}

function tileMedia(document) {
  const tile = document.querySelector("#grid .tile");
  return {
    canvas: tile.querySelector(".frame-wrap canvas"),
    img: tile.querySelector(".frame-wrap img"),
  };
}

test("h264 描画中、stream 無しの遅延ポーリングフレームは canvas 表示を維持する(デコーダを破棄しない)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  await sendKeyframeAndAwaitH264(window);

  const before = tileMedia(document);
  assert.ok(before.canvas.classList.contains("visible"), "前提: h264 の初回フレームで canvas 表示になっている");
  assert.ok(before.img.classList.contains("h264-hidden"), "前提: img は隠れている");

  // 安全弁フレーム(stream フィールド無し = 定期ポーリング由来)
  post(window, { type: "frame", device: "android:Emu 1", jpegBase64: "AAAA", width: 400, height: 800 });

  const after = tileMedia(document);
  assert.ok(after.canvas.classList.contains("visible"), "stream 無しのフレーム1枚で canvas 表示から外れてはいけない");
  assert.ok(after.img.classList.contains("h264-hidden"), "img が表に出てはいけない(=デコーダを破棄していない)");
});

test("stream:true(mjpeg 正式フォールバック)は h264 表示を静止画へ戻す", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  await sendKeyframeAndAwaitH264(window);

  post(window, { type: "frame", device: "android:Emu 1", jpegBase64: "AAAA", width: 400, height: 800, stream: true });

  const after = tileMedia(document);
  assert.ok(!after.canvas.classList.contains("visible"), "mjpeg 正式フォールバックでは canvas から img へ戻ること");
  assert.ok(!after.img.classList.contains("h264-hidden"), "img が表示に戻ること");
});

// 縦横比は**表示している媒体から**決める。h264(canvas)表示中に、安全弁のポーリングが届けた
// 別の向きの1枚(隠れた img)が load しても、タイルの比率を変えない(縦長の映像が横長の枠に
// 入った 2026-09-17)。正式に img へ戻ったときだけ img の実寸に合わせる
function loadImage(window, img, width, height) {
  Object.defineProperty(img, "naturalWidth", { configurable: true, get: () => width });
  Object.defineProperty(img, "naturalHeight", { configurable: true, get: () => height });
  img.dispatchEvent(new window.Event("load"));
}

function tileAspect(document) {
  return document.querySelector("#grid .tile").style.getPropertyValue("--tile-aspect");
}

test("h264 表示中に届いた別の向きの静止画は、タイルの縦横比を変えない", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  await sendKeyframeAndAwaitH264(window);
  assert.equal(tileAspect(document), "0.5000", "前提: canvas(400x800)の比率");

  post(window, { type: "frame", device: "android:Emu 1", jpegBase64: "AAAA", width: 800, height: 400 });
  loadImage(window, tileMedia(document).img, 800, 400);

  assert.equal(tileAspect(document), "0.5000", "隠れた img の load で横長にしてはいけない");
});

test("img へ正式に戻ったら、img の実寸で縦横比を取り直す", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  await sendKeyframeAndAwaitH264(window);
  assert.equal(tileAspect(document), "0.5000", "前提: canvas(400x800)の比率");
  const img = tileMedia(document).img;
  Object.defineProperty(img, "naturalWidth", { configurable: true, get: () => 800 });
  Object.defineProperty(img, "naturalHeight", { configurable: true, get: () => 400 });

  post(window, { type: "frame", device: "android:Emu 1", jpegBase64: "AAAA", width: 800, height: 400, stream: true });

  assert.equal(tileAspect(document), "2.0000", "img 表示に戻ったら img の比率");
});
