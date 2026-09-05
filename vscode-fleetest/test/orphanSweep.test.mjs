// orphanSweep.test.mjs
// orphanSweep.ts(parseOrphanPids)のユニットテスト。node:test で実行する。
// esbuild が "../src/orphanSweep"(拡張子なし)を orphanSweep.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { parseOrphanPids } from "../src/orphanSweep";

test("parseOrphanPids: PPID=1 の live serve / host-metrics / monitor を抽出する", () => {
  const psOutput = [
    "  111     1 .build/debug/fleetest api live serve --platform ios --port 8127",
    "  222     1 .build/debug/fleetest api host-metrics --interval 1",
    "  333     1 .build/debug/fleetest api monitor --project SampleApp --interval 1 --max-width 800",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), [111, 222, 333]);
});

test("parseOrphanPids: PPID が 1 でない同コマンドは除外する", () => {
  const psOutput = [
    "  111  4321 .build/debug/fleetest api live serve --platform ios --port 8127",
    "  222  4321 .build/debug/fleetest api host-metrics --interval 1",
    "  333  4321 .build/debug/fleetest api monitor --project SampleApp --interval 1",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), []);
});

test("parseOrphanPids: PPID=1 の api run はデバイス占有解除のため対象に含める", () => {
  const psOutput = "  111     1 .build/debug/fleetest api run --project SampleApp --scenario Foo";
  assert.deepEqual(parseOrphanPids(psOutput), [111]);
});

test("parseOrphanPids: PPID=1 でも api run 以外の非常駐コマンド(api gen-scenario 等)は除外する", () => {
  const psOutput = "  222     1 .build/debug/fleetest api gen-scenario --project SampleApp";
  assert.deepEqual(parseOrphanPids(psOutput), []);
});

test("parseOrphanPids: PPID=1 でも無関係コマンドは除外する(grep 引数中の fleetest/monitor に誤爆しない)", () => {
  const psOutput = [
    "  111     1 grep fleetest api monitor",
    "  222     1 /usr/bin/vim notes.txt",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), []);
});

test("parseOrphanPids: 相対パス(.build/debug/fleetest)を抽出する", () => {
  const psOutput = "  111     1 .build/debug/fleetest api monitor --project SampleApp --interval 1";
  assert.deepEqual(parseOrphanPids(psOutput), [111]);
});

test("parseOrphanPids: 絶対パス(/Users/x/foundation-tester/.build/debug/fleetest)を抽出する", () => {
  const psOutput =
    "  111     1 /Users/x/foundation-tester/.build/debug/fleetest api live serve --platform android --serial emulator-5554";
  assert.deepEqual(parseOrphanPids(psOutput), [111]);
});

test("parseOrphanPids: 空出力は空配列", () => {
  assert.deepEqual(parseOrphanPids(""), []);
});

test("parseOrphanPids: PPID=1 の `remote exec <machine> -- api device-stream` を抽出する", () => {
  const psOutput =
    "  555     1 .build/debug/fleetest remote exec M1Max -- api device-stream --device-machine local --platform ios --name iPhone-01";
  assert.deepEqual(parseOrphanPids(psOutput), [555]);
});

test("parseOrphanPids: PPID=1 の fleetest-androidstream(絶対パス前置)を抽出する", () => {
  const psOutput =
    "  666     1 /Users/x/foundation-tester/.build/debug/fleetest-androidstream --serial emulator-5554 --fps 8 --max-width 800";
  assert.deepEqual(parseOrphanPids(psOutput), [666]);
});

test("parseOrphanPids: PPID=1 の fleetest-devicepoll / fleetest-simstream(パス前置無し)を抽出する", () => {
  const psOutput = [
    "  777     1 fleetest-devicepoll --platform ios --host 127.0.0.1 --port 8127 --fps 8 --max-width 800",
    "  888     1 fleetest-simstream --udid ABCDEF01-1234-1234-1234-1234567890AB --fps 8 --max-width 800",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), [777, 888]);
});

test("parseOrphanPids: PPID が 1 でない配信プロセスは除外する", () => {
  const psOutput = [
    "  555  4321 .build/debug/fleetest remote exec M1Max -- api device-stream --device-machine local --platform ios --name iPhone-01",
    "  666  4321 /Users/x/foundation-tester/.build/debug/fleetest-androidstream --serial emulator-5554",
    "  777  4321 fleetest-devicepoll --platform ios --port 8127",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), []);
});

test("parseOrphanPids: PPID=1 でも `api gen-scenario --name monitor` は除外する(引数中の語に誤爆しない)", () => {
  const psOutput = "  999     1 .build/debug/fleetest api gen-scenario --name monitor";
  assert.deepEqual(parseOrphanPids(psOutput), []);
});

test("parseOrphanPids: 不正行(数値でない PID/PPID・ヘッダ行)はスキップする", () => {
  const psOutput = [
    "PID PPID COMMAND",
    "  abc     1 .build/debug/fleetest api monitor --project SampleApp",
    "",
    "   ",
    "  444     1 .build/debug/fleetest api live serve --platform ios",
  ].join("\n");
  assert.deepEqual(parseOrphanPids(psOutput), [444]);
});
