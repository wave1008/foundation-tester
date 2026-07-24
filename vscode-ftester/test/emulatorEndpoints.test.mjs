// emulatorGrpc.test.mjs
// emulatorEndpoints.ts(parseEmulatorIni)のユニットテスト。node:test で実行する。
// esbuild が "../src/emulatorEndpoints"(拡張子なし)を emulatorGrpc.ts に解決してバンドルする。
// gRPC 呼び出し系(grpcProbeBlank/grpcSleepWake)はここではテストしない(実エミュレータ依存)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { parseEmulatorIni, isUniformRgba } from "../src/emulatorEndpoints";

test("parseEmulatorIni: 4キー全て揃っていれば EmulatorEndpoint を返す", () => {
  const text = ["avd.id=Pixel_9_Android_15_-01", "port.serial=5554", "grpc.port=8554", "grpc.token=abc123"].join(
    "\n",
  );
  assert.deepEqual(parseEmulatorIni(text, 4242), {
    serial: "emulator-5554",
    avdId: "Pixel_9_Android_15_-01",
    grpcPort: 8554,
    token: "abc123",
    pid: 4242,
  });
});

test("parseEmulatorIni: grpc.token が内部に '=' を含んでいても行内最初の '=' でのみ分割し、値全体を保持する", () => {
  const text = [
    "avd.id=Pixel_9_Android_15_-01",
    "port.serial=5554",
    "grpc.port=8554",
    "grpc.token=YWJjMTIz==padding==",
  ].join("\n");
  const endpoint = parseEmulatorIni(text, 4242);
  assert.equal(endpoint?.token, "YWJjMTIz==padding==");
});

test("parseEmulatorIni: grpc.token が欠落していれば undefined", () => {
  const text = ["avd.id=Pixel_9_Android_15_-01", "port.serial=5554", "grpc.port=8554"].join("\n");
  assert.equal(parseEmulatorIni(text, 4242), undefined);
});

test("parseEmulatorIni: port.serial=5556 なら serial は emulator-5556", () => {
  const text = ["avd.id=Pixel_9_Android_15_-01", "port.serial=5556", "grpc.port=8556", "grpc.token=tok"].join("\n");
  assert.equal(parseEmulatorIni(text, 1)?.serial, "emulator-5556");
});

test("parseEmulatorIni: grpc.port が欠落していれば undefined", () => {
  const text = ["avd.id=Pixel_9_Android_15_-01", "port.serial=5554", "grpc.token=abc123"].join("\n");
  assert.equal(parseEmulatorIni(text, 4242), undefined);
});

test("parseEmulatorIni: grpc.port が非数値(garbage)なら undefined", () => {
  const text = ["avd.id=Pixel_9_Android_15_-01", "port.serial=5554", "grpc.port=not-a-number", "grpc.token=abc123"].join(
    "\n",
  );
  assert.equal(parseEmulatorIni(text, 4242), undefined);
});

test("isUniformRgba: 一様黒/一様白は blank(実凍結フレームは spread 0)", () => {
  const black = new Uint8Array(1000 * 4);
  for (let i = 3; i < black.length; i += 4) black[i] = 255;
  assert.equal(isUniformRgba(black), true);
  const white = new Uint8Array(1000 * 4).fill(255);
  assert.equal(isUniformRgba(white), true);
});

test("isUniformRgba: tolerance 内の微小ノイズは一様扱い", () => {
  const noisy = new Uint8Array(1000 * 4).fill(100);
  noisy[500 * 4] = 104;
  noisy[500 * 4 + 1] = 96;
  assert.equal(isUniformRgba(noisy), true);
});

test("isUniformRgba: 実コンテンツ(グラデーション)は非一様", () => {
  const grad = new Uint8Array(1000 * 4);
  for (let p = 0; p < 1000; p++) {
    grad[p * 4] = p % 256;
    grad[p * 4 + 1] = 50;
    grad[p * 4 + 2] = 200;
    grad[p * 4 + 3] = 255;
  }
  assert.equal(isUniformRgba(grad), false);
});

test("isUniformRgba: 空・4バイト未満は判定不能= false(安全側)", () => {
  assert.equal(isUniformRgba(new Uint8Array(0)), false);
  assert.equal(isUniformRgba(new Uint8Array([1, 2, 3])), false);
});
