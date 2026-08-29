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

// --- v1(mjpeg)---

/** v1 レコード1件分(WIDTH/HEIGHT/LEN/JPEG)。jpeg は SOI 検査を通す実体を渡すこと。 */
function buildMjpegRecord(width, height, jpeg) {
  const header = Buffer.alloc(8);
  header.writeUInt16BE(width, 0);
  header.writeUInt16BE(height, 2);
  header.writeUInt32BE(jpeg.length, 4);
  return Buffer.concat([header, jpeg]);
}

const JPEG_BODY = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);

function createMjpegHarness() {
  const logLines = [];
  const frames = [];
  const pipeline = new StreamPipeline({
    command: "unused",
    args: [],
    logPrefix: "test-stream",
    outputChannel: { appendLine: (line) => logLines.push(line) },
    codec: "mjpeg",
    onFrame: (jpegBase64, width, height) => {
      frames.push({ jpegBase64, width, height });
    },
    onConnectionOk: () => undefined,
    onFailure: () => undefined,
  });
  return { logLines, frames, ingest: (chunk) => pipeline.ingest(chunk) };
}

test("mjpeg: 分割着信しても1件パースでき、寸法をそのまま渡す", () => {
  const h = createMjpegHarness();
  const record = buildMjpegRecord(221, 480, JPEG_BODY);
  h.ingest(record.subarray(0, 5));
  assert.equal(h.frames.length, 0, "ヘッダ未完のうちは onFrame が呼ばれてはいけない");
  h.ingest(record.subarray(5));

  assert.equal(h.frames.length, 1);
  assert.equal(h.frames[0].width, 221);
  assert.equal(h.frames[0].height, 480);
  assert.equal(h.frames[0].jpegBase64, JPEG_BODY.toString("base64"));
});

test("mjpeg: 寸法 0 のヘッダは desync として弾き、フレームを流さない", () => {
  const h = createMjpegHarness();
  h.ingest(buildMjpegRecord(0, 0, JPEG_BODY));

  assert.equal(h.frames.length, 0);
  assert.ok(
    h.logLines.some((line) => line.includes("境界がずれています")),
    `desync のログが出力されていない: ${JSON.stringify(h.logLines)}`,
  );
});

test("mjpeg: JPEG でないペイロード(境界ズレ)は弾き、以後の同一チャンク分も破棄する", () => {
  const h = createMjpegHarness();
  const bad = buildMjpegRecord(100, 200, Buffer.from([0x00, 0x01, 0x02, 0x03]));
  const good = buildMjpegRecord(221, 480, JPEG_BODY);
  h.ingest(Buffer.concat([bad, good]));

  assert.equal(h.frames.length, 0);
  assert.ok(
    h.logLines.some((line) => line.includes("境界がずれています")),
    `desync のログが出力されていない: ${JSON.stringify(h.logLines)}`,
  );
});

// ---- helper が「この機械では h264 が無理」と降りたとき(exit 3) ----------------------------
// 実害(2026-08-17): 20 タイル構成で VideoToolbox の圧縮セッションが壊れ(-17691
// kVTSessionMalfunctionErr)、simstream は警告を出すだけで AU を1本も書かなくなった。
// StreamPipeline は 15 秒の無フレーム監視で kill→再起動を繰り返すが、**同じ引数では直らない**
// のでタイルが永久に「接続中」になった。exit 3 は「形式を変えて張り直せ」の合図で、
// **再起動してはいけない**(同じ h264 でまた失敗する)。
//
// contract: Sources/fleetest-simstream/main.m の kFtExitCodecUnavailable と同値

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/** 指定の exit code で即終了するだけの mock helper を置く。 */
function makeExitingHelper(code) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-stream-exit-"));
  const helper = path.join(dir, "helper");
  fs.writeFileSync(helper, `#!/bin/sh\nexit ${code}\n`);
  fs.chmodSync(helper, 0o755);
  return { dir, helper };
}

async function waitFor(predicate, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise((r) => setTimeout(r, 20));
  }
  return false;
}

test("exit 3 は onCodecUnavailable を呼び、再起動しない", async () => {
  const { dir, helper } = makeExitingHelper(3);
  let codecUnavailable = 0;
  let failures = 0;
  const pipeline = new StreamPipeline({
    command: helper, args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { failures += 1; },
    onCodecUnavailable: () => { codecUnavailable += 1; },
  });
  try {
    pipeline.start();
    assert.ok(await waitFor(() => codecUnavailable > 0), "mjpeg で張り直させる合図が要る");
    // 再起動していたら 2 回目以降の exit で加算される(RESTART_DELAY_MS 分待つ)
    await new Promise((r) => setTimeout(r, 1200));
    assert.equal(codecUnavailable, 1, "同じ引数で再起動しない(h264 でまた失敗するだけ)");
    assert.equal(failures, 0, "諦めた扱いにはしない(mjpeg で張り直せる)");
  } finally {
    pipeline.dispose();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("それ以外の exit code は従来どおり再起動する(諦めまで数える)", async () => {
  const { dir, helper } = makeExitingHelper(1);
  let codecUnavailable = 0;
  let failures = 0;
  const pipeline = new StreamPipeline({
    command: helper, args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { failures += 1; },
    onCodecUnavailable: () => { codecUnavailable += 1; },
  });
  try {
    pipeline.start();
    assert.ok(await waitFor(() => failures > 0, 8000), "連続失敗で諦めてポーリングへ落ちる");
    assert.equal(codecUnavailable, 0, "codec のせいだと決めつけない");
  } finally {
    pipeline.dispose();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// 1フレームも届かないまま wedge を繰り返す台は諦める。
// 実害(2026-08-17): 20 タイル同時配信でホストがエンコードをこなせなくなり(h264 は
// kVTSessionMalfunctionErr、mjpeg は "JPEG encode failed")、**15秒ごとの再起動を無限に
// 繰り返した**。再起動そのものが CPU を食うので、資源不足が原因のときは事態を悪化させる。
// wedge 由来の kill は必ず healthy 窓(10秒)の外なので、既存の連続失敗カウントでは
// 永久に give-up に到達しない —— 「一度も届いていない」を別に数える必要がある。
test("1フレームも届かないまま wedge を繰り返したら諦める(無限再起動を止める)", async () => {
  // 何も出さずに生き続ける helper(= 無フレーム)。wedge の 15 秒を待たずに検証するため
  // handleWedge を直接呼ぶ(private だが実行時は通常のメソッド。このファイルの方針参照)
  const { dir } = makeExitingHelper(0);
  const helper = path.join(dir, "silent");
  fs.writeFileSync(helper, "#!/bin/sh\nexec sleep 120\n");
  fs.chmodSync(helper, 0o755);
  let failures = 0;
  const pipeline = new StreamPipeline({
    command: helper, args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { failures += 1; },
  });
  try {
    pipeline.start();
    // wedge 1回目: 再起動する(諦めない)
    pipeline.handleWedge();
    assert.ok(await waitFor(() => !pipeline.isRunning(), 3000), "前提: kill される");
    assert.equal(failures, 0, "1回目は張り直して様子を見る");
    assert.ok(await waitFor(() => pipeline.isRunning(), 4000), "再起動する");
    // wedge 2回目: ここで諦める
    pipeline.handleWedge();
    assert.ok(await waitFor(() => failures > 0, 5000), "2回目で諦めてポーリングへ落ちる");
  } finally {
    pipeline.dispose();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ping(KIND=3)は「映像が来た」証拠にしない。**静止画面の Android は ping だけで正常**なので
// 数えてしまうと、そこは救われる一方で「一度も届いていない」判定が効かなくなる
// (= 無限再起動が復活する)。ping は wedge のリセットにだけ使う。
test("ping はフレームに数えない(諦め判定を殺さない)", async () => {
  const { dir } = makeExitingHelper(0);
  const helper = path.join(dir, "silent");
  fs.writeFileSync(helper, "#!/bin/sh\nexec sleep 120\n");
  fs.chmodSync(helper, 0o755);
  let failures = 0;
  const pipeline = new StreamPipeline({
    command: helper, args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { failures += 1; },
  });
  try {
    pipeline.start();
    pipeline.ingest(buildRecord(KIND_PING, 0, 0, 0, Buffer.alloc(0)));
    pipeline.handleWedge();
    assert.ok(await waitFor(() => pipeline.isRunning() === false, 3000));
    assert.ok(await waitFor(() => pipeline.isRunning(), 4000));
    pipeline.handleWedge();
    assert.ok(await waitFor(() => failures > 0, 5000),
      "ping しか来ていない台は「映像が来た」扱いにしてはいけない");
  } finally {
    pipeline.dispose();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---- 遅い失敗が諦めの上限をすり抜けないこと ----
//
// 実害(2026-08-30 の一括起動): ランナーへの ssh が混雑し、1本あたり約 10〜11 秒かけて
// `Connection timed out during banner exchange` で失敗していた。諦めの判定は
// 「HEALTHY_WINDOW_MS(10秒)以内の終了」だけを連続失敗として数えるので、毎回 streak が
// 0 に戻り、**混雑しているホストを永久に叩き続けた**。時間ではなく「1フレームも来なかったか」
// で数える(NO_FRAME_WEDGE_LIMIT と同じ判断)。
//
// 実プロセスで 10 秒超を 3 回再現すると 30 秒以上かかるので、private の内部状態を直接置いて
// handleUnexpectedExit を呼ぶ(このファイルの他のテストが ingest() を直接呼ぶのと同じ方針)。
function newPipeline(onFailureCount) {
  return new StreamPipeline({
    command: "/nonexistent", args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { onFailureCount.n += 1; },
    onCodecUnavailable: () => {},
  });
}

test("1フレームも来ないまま終わる失敗は、遅くても諦めの上限に数える", () => {
  const failures = { n: 0 };
  const pipeline = new StreamPipeline({
    command: "/nonexistent", args: [], logPrefix: "ios-stream",
    outputChannel: { appendLine() {} }, codec: "h264",
    onFrame: () => {}, onChunk: () => {}, onConnectionOk: () => {},
    onFailure: () => { failures.n += 1; },
    onCodecUnavailable: () => {},
  });
  try {
    for (let i = 0; i < 3; i += 1) {
      pipeline.startedAt = Date.now() - 20000;  // 10秒より長く生きてから失敗(= ssh タイムアウト)
      pipeline.everDeliveredFrame = false;      // 1枚も届いていない
      pipeline.handleUnexpectedExit("exit code 1");
    }
    assert.equal(failures.n, 1, "遅い失敗が3回続いたら諦めてポーリングへ落ちる");
  } finally {
    pipeline.dispose();
  }
});

test("一度でも映像が届いた後の終了は、何度でも張り直す(streak を戻す)", () => {
  const failures = { n: 0 };
  const pipeline = newPipeline(failures);
  try {
    for (let i = 0; i < 5; i += 1) {
      pipeline.startedAt = Date.now() - 20000;
      pipeline.everDeliveredFrame = true;      // 映像は来ていた = 本物の wedge/切断
      pipeline.handleUnexpectedExit("wedge");
    }
    assert.equal(failures.n, 0, "動いていた配信は諦めずに張り直す(ここを巻き込むと退行)");
  } finally {
    pipeline.dispose();
  }
});
