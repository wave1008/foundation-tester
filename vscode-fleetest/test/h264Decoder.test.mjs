// h264Decoder.test.mjs
// createH264Renderer の「デコード実寸の通知」契約テスト。
// VideoFrame は close() で detach され displayWidth/Height が 0 を返す(WebCodecs 仕様)。
// close 後に読んでいたため H.264 タイルはアスペクト比を一度も採れず、枠が既定値のまま
// 残っていた(実害 2026-07-29。docs/design.md §12.1)。
//
// 検証対象:
// - onFirstFrame/onDimensions が close 前の実寸を受け取る(0 が渡らない)
// - 解像度が変わったら onDimensions が再び呼ばれる(初回だけだと枠に古い比率が残る)

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { createH264Renderer } from "../src/webview/monitor/h264Decoder.js";

// 先頭付近に SPS(NAL type 7)がある Annex-B。findAvcCodecString が avc1.42001f を組む
const KEYFRAME = new Uint8Array([0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 1, 0x65, 0x88]);

// close() で 0 になる実 VideoFrame の振る舞いを再現する
function makeFrame(width, height) {
  return {
    displayWidth: width,
    displayHeight: height,
    close() {
      this.displayWidth = 0;
      this.displayHeight = 0;
    },
  };
}

function fakeCanvas() {
  return { width: 0, height: 0, getContext: () => ({ drawImage() {} }) };
}

// decode() のたびに frames を先頭から1枚 output する偽デコーダを global へ挿す
function installWebCodecs(frames) {
  globalThis.VideoDecoder = class {
    static isConfigSupported() {
      return Promise.resolve({ supported: true });
    }
    constructor({ output }) {
      this.output = output;
    }
    configure() {}
    decode() {
      const frame = frames.shift();
      if (frame) {
        this.output(frame);
      }
    }
    close() {}
  };
  globalThis.EncodedVideoChunk = class {
    constructor(init) {
      Object.assign(this, init);
    }
  };
}

// configure は isConfigSupported の Promise 解決後に flush する(マイクロタスク待ち)
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  delete globalThis.VideoDecoder;
  delete globalThis.EncodedVideoChunk;
});

test("初回フレームの実寸は close 前の値が渡る(0 にならない)", async () => {
  installWebCodecs([makeFrame(1080, 2424)]);
  const dims = [];
  let firstFrame = null;
  const renderer = createH264Renderer({
    canvas: fakeCanvas(),
    onError: () => assert.fail("onError が呼ばれた"),
    onFirstFrame: (d) => { firstFrame = d; },
    onDimensions: (d) => dims.push(d),
  });

  renderer.pushChunk(KEYFRAME, true, 0, 0);
  await settle();

  assert.deepEqual(firstFrame, { width: 1080, height: 2424 });
  assert.deepEqual(dims, [{ width: 1080, height: 2424 }]);
});

test("解像度が変わったら onDimensions が再び呼ばれる", async () => {
  installWebCodecs([makeFrame(1080, 2424), makeFrame(480, 1080)]);
  const dims = [];
  const renderer = createH264Renderer({
    canvas: fakeCanvas(),
    onError: () => assert.fail("onError が呼ばれた"),
    onFirstFrame: () => {},
    onDimensions: (d) => dims.push(d),
  });

  renderer.pushChunk(KEYFRAME, true, 0, 0);
  await settle();
  // 描画は 66ms に間引かれる(間隔を空けないと2枚目は捨てられる)
  await new Promise((resolve) => setTimeout(resolve, 80));
  renderer.pushChunk(KEYFRAME, true, 0, 0);
  await settle();

  assert.deepEqual(dims, [{ width: 1080, height: 2424 }, { width: 480, height: 1080 }]);
});
