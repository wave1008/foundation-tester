// デバイスモニターの「ライブ操作」タブで、タップ等の操作結果として届く 'snapshot'
// (jpeg 一枚絵 + 要素一覧)を受けたとき、**デコーダを捨てずに**前面だけ一枚絵へ入れ替えることの
// 回帰テスト。
//
// 守っているものが2つある:
//   - デコーダを作り直さない(実害 docs/bug-audit-2026-09-06.md §3 liveTab.js:382):
//     作り直すと次のキーフレームまで1枚も描けず、タップのたびに映像が数秒止まる。
//     h264 のキーフレームは「画面が動いてから最大 4 秒」かつ静止中はそもそもエンコードされない
//     (fleetest-simstream の MaxKeyFrameIntervalDuration と keepalive)ので、実測で 10 秒を超えた。
//   - 届いた一枚絵をすぐ出す(実害 2026-09-21): 配信は静止画面でエンコードを止めるため、
//     canvas を尊重して待つと「木はもう次の画面なのに絵が切り替わらない」状態が続く。
//     snapshot は host が tap の**あと**に撮って返すので、配信より新しい。
// 'frame' メッセージ(host が完全に mjpeg 配信へ切り替えた場合)はこれまで通りデコーダを捨てる。
//
// jsdom には 2D canvas コンテキストが無い(canvas パッケージ未導入)ため、
// HTMLCanvasElement.prototype.getContext と VideoDecoder/EncodedVideoChunk をテスト用に
// 差し替える(h264Decoder.test.mjs / webviewTileStreamStalePoll.test.mjs と同型のフェイク)。
// harness(monitorHtml.ts + webview/monitor/main.js の実バンドル)は webviewLiveDrag.test.mjs と同型。

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
  const webviewStub = {
    asWebviewUri: (uri) => `https://localhost${uri.path}`,
    cspSource: "https://localhost",
  };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

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
  window.acquireVsCodeApi = () => ({
    postMessage: () => {}, setState: () => {}, getState: () => undefined,
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
  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

async function sendKeyframeAndAwaitH264(window) {
  post(window, { type: "liveH264Chunk", keyframe: true, width: 0, height: 0, data: KEYFRAME });
  await settle();
}

function media(document) {
  return {
    canvas: document.getElementById("live-canvas"),
    screenshot: document.getElementById("live-screenshot"),
  };
}

test("snapshot は届いた一枚絵を前面へ出す(配信の古い絵を残さない)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  await sendKeyframeAndAwaitH264(window);

  const before = media(document);
  assert.ok(before.canvas.classList.contains("visible"), "前提: 初回 h264 フレームで canvas 表示になっている");
  assert.ok(!before.screenshot.classList.contains("visible"), "前提: screenshot(img)は隠れている");

  post(window, {
    type: "live",
    message: { type: "snapshot", screen: { width: 400, height: 800 }, image: "AAAA", elements: [] },
  });

  const after = media(document);
  assert.ok(after.screenshot.classList.contains("visible"), "届いた一枚絵を前面へ出すこと");
  assert.ok(!after.canvas.classList.contains("visible"), "配信の古い絵を前面に残さないこと");
  assert.ok(after.screenshot.src.endsWith("AAAA"), "出すのは届いたばかりの絵であること");
});

// **デコーダを作り直していないことは「キーフレーム無しのデルタで描けるか」で判る** ——
// 作り直していれば sawKeyframe が落ちてデルタは全部捨てられ、canvas は前へ戻れない。
test("snapshot のあと、デルタ1枚で canvas が前面に戻る(デコーダを作り直していない)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  await sendKeyframeAndAwaitH264(window);

  post(window, {
    type: "live",
    message: { type: "snapshot", screen: { width: 400, height: 800 }, image: "AAAA", elements: [] },
  });
  assert.ok(media(document).screenshot.classList.contains("visible"), "前提: 一枚絵が前面");

  // 描画間引き(h264Decoder の DRAW_INTERVAL_MS=66ms)を跨がせてから delta を1枚
  const base = window.performance.now();
  window.performance.now = () => base + 100;
  post(window, { type: "liveH264Chunk", keyframe: false, width: 0, height: 0, data: KEYFRAME });
  await settle();

  const after = media(document);
  assert.ok(after.canvas.classList.contains("visible"), "描けた時点で canvas が前面に戻ること");
  assert.ok(!after.screenshot.classList.contains("visible"), "一枚絵は下がること");
});

test("'frame'(host が mjpeg 配信へ切替済み)は引き続き静止画表示へ戻す", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  await sendKeyframeAndAwaitH264(window);

  post(window, { type: "live", message: { type: "frame", image: "AAAA" } });

  const after = media(document);
  assert.ok(!after.canvas.classList.contains("visible"), "'frame' では canvas から img へ戻ること");
  assert.ok(after.screenshot.classList.contains("visible"), "screenshot(img)が表示に戻ること");
});
