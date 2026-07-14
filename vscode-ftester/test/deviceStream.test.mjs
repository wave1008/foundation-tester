// deviceStream.test.mjs
// StreamPipeline(src/deviceStream.ts)の v2(--codec h264)stdout パーサのユニットテスト。
// node:test で実行する。esbuild が "../src/deviceStream"(拡張子なし)を deviceStream.ts に
// 解決してバンドルする(deviceStream.ts の OutputChannel 型 import は `import type` なので
// esbuild が完全に除去し、実行時に "vscode" モジュール解決は不要)。
//
// StreamPipeline.ingest() は private だが、TypeScript の private はコンパイル時のみの制約で
// 実行時には通常のメソッドとして残る(esbuild は型を消すだけで private を強制しない)。この
// テストファイル自体も型検査対象外(tsconfig.json は test/**/*.mts のみを include、この
// ファイルは .test.mjs)なので、実プロセスを spawn せず ingest() を直接呼んでパーサだけを検証する
// (start() を呼ばないため this.process は常に undefined = 未知 KIND 時の kill はログのみになる)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { StreamPipeline } from "../src/deviceStream";

const KIND_AU = 2;
const KIND_PING = 3;

/** v2 レコード1件分のバイト列(KIND/FLAGS/WIDTH/HEIGHT/LEN/DATA)を組み立てる。 */
function buildRecord(kind, flags, width, height, data) {
  const header = Buffer.alloc(10);
  header.writeUInt8(kind, 0);
  header.writeUInt8(flags, 1);
  header.writeUInt16BE(width, 2);
  header.writeUInt16BE(height, 4);
  header.writeUInt32BE(data.length, 6);
  return Buffer.concat([header, data]);
}

/** StreamPipeline を codec="h264" で生成し、受信したコールバックを配列に集めて返す
 * (start() は呼ばない。ingest() を直接呼ぶテスト用ヘルパー)。 */
function createH264Harness() {
  const logLines = [];
  const chunks = [];
  let connectionOkCount = 0;
  const failures = [];
  const pipeline = new StreamPipeline({
    command: "unused",
    args: [],
    logPrefix: "test-stream",
    outputChannel: { appendLine: (line) => logLines.push(line) },
    codec: "h264",
    onFrame: () => {
      throw new Error("codec=h264 のとき onFrame は呼ばれてはならない");
    },
    onChunk: (data, keyframe, width, height) => {
      chunks.push({ data: Buffer.from(data), keyframe, width, height });
    },
    onConnectionOk: () => {
      connectionOkCount += 1;
    },
    onFailure: (message) => {
      failures.push(message);
    },
  });
  return {
    pipeline,
    logLines,
    chunks,
    failures,
    connectionOkCount: () => connectionOkCount,
    ingest: (chunk) => pipeline.ingest(chunk),
  };
}

test("h264: 10バイトヘッダが複数チャンクに分割着信しても正しく1件パースできる", () => {
  const h = createH264Harness();
  const data = Buffer.from([0xaa, 0xbb, 0xcc, 0xdd, 0xee]);
  const record = buildRecord(KIND_AU, 1 /* keyframe */, 480, 1040, data);

  // ヘッダの途中(4バイト目)で分断する極端なケース。
  h.ingest(record.subarray(0, 4));
  assert.equal(h.chunks.length, 0, "ヘッダ未完のうちは onChunk が呼ばれてはいけない");
  h.ingest(record.subarray(4));

  assert.equal(h.chunks.length, 1);
  const chunk = h.chunks[0];
  assert.equal(chunk.keyframe, true);
  assert.equal(chunk.width, 480);
  assert.equal(chunk.height, 1040);
  assert.deepEqual(chunk.data, data);
  assert.equal(h.connectionOkCount(), 1);
});

test("h264: ヘッダ完了後、DATA本体が複数チャンクに分割着信しても正しく1件パースできる", () => {
  const h = createH264Harness();
  const data = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
  const record = buildRecord(KIND_AU, 0 /* delta frame */, 320, 640, data);

  h.ingest(record.subarray(0, 15)); // ヘッダ10バイト+DATA先頭5バイト
  h.ingest(record.subarray(15, 25)); // DATA続き
  h.ingest(record.subarray(25)); // DATA残り

  assert.equal(h.chunks.length, 1);
  assert.equal(h.chunks[0].keyframe, false);
  assert.deepEqual(h.chunks[0].data, data);
});

test("h264: 1チャンクに複数レコードがまとまっていても全件パースできる", () => {
  const h = createH264Harness();
  const a = buildRecord(KIND_AU, 1, 100, 200, Buffer.from([1, 2, 3]));
  const b = buildRecord(KIND_AU, 0, 100, 200, Buffer.from([4, 5]));
  h.ingest(Buffer.concat([a, b]));

  assert.equal(h.chunks.length, 2);
  assert.equal(h.chunks[0].keyframe, true);
  assert.deepEqual(h.chunks[0].data, Buffer.from([1, 2, 3]));
  assert.equal(h.chunks[1].keyframe, false);
  assert.deepEqual(h.chunks[1].data, Buffer.from([4, 5]));
});

test("h264: KIND=3(ping)は onConnectionOk のみで onChunk は呼ばれない", () => {
  const h = createH264Harness();
  const ping = buildRecord(KIND_PING, 0, 0, 0, Buffer.alloc(0));
  h.ingest(ping);

  assert.equal(h.chunks.length, 0);
  assert.equal(h.connectionOkCount(), 1);
});

test("h264: 未知 KIND はログして以後の同一チャンク分を破棄する(kill はプロセス不在のためログのみ)", () => {
  const h = createH264Harness();
  const bad = buildRecord(99, 0, 0, 0, Buffer.alloc(0));
  const good = buildRecord(KIND_AU, 1, 10, 10, Buffer.from([9]));
  // 未知 KIND の直後に正規レコードが同一チャンクに続いていても、buffer 全体を破棄するため
  // 後続の good は処理されない(プロトコル不整合検出後は helper の再起動待ちに徹する契約)。
  h.ingest(Buffer.concat([bad, good]));

  assert.equal(h.chunks.length, 0);
  assert.equal(h.failures.length, 0); // handleUnknownKind は onFailure を呼ばない(kill→自動再起動に委ねる)
  assert.ok(
    h.logLines.some((line) => line.includes("未知の KIND")),
    `未知 KIND のログが出力されていない: ${JSON.stringify(h.logLines)}`,
  );
});
