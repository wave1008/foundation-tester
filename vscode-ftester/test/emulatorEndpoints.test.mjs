// emulatorGrpc.test.mjs
// emulatorEndpoints.ts(parseEmulatorIni)のユニットテスト。node:test で実行する。
// esbuild が "../src/emulatorEndpoints"(拡張子なし)を emulatorGrpc.ts に解決してバンドルする。
// gRPC 呼び出し系(grpcScreenshotPngBytes/grpcSleepWake)はここではテストしない(実エミュレータ依存)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { parseEmulatorIni } from "../src/emulatorEndpoints";

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
