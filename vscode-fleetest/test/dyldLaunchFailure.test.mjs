// dyldLaunchFailure.test.mjs
// detectDyldLaunchFailure / DyldNotifyGate (src/dyldLaunchFailure.ts) のユニットテスト。
// vscode に依存しない純関数だけを対象にする(node:test で直接実行できる)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { detectDyldLaunchFailure, DyldNotifyGate } from "../src/dyldLaunchFailure";

test("当たる: [pid] 付きの Symbol not found", () => {
  const line = detectDyldLaunchFailure(
    "dyld[1234]: Symbol not found: _$s16FoundationModels14LanguageModelVMn\n",
  );
  assert.equal(line, "dyld[1234]: Symbol not found: _$s16FoundationModels14LanguageModelVMn");
});

test("当たる: [pid] 付きの Library not loaded", () => {
  const line = detectDyldLaunchFailure("dyld[5]: Library not loaded: @rpath/libx.dylib");
  assert.equal(line, "dyld[5]: Library not loaded: @rpath/libx.dylib");
});

test("当たる: 旧形式([pid] 無し)の Symbol not found", () => {
  const line = detectDyldLaunchFailure("dyld: Symbol not found: _foo");
  assert.equal(line, "dyld: Symbol not found: _foo");
});

test("当たる: 前後に別の行が混ざっていても該当行を拾う", () => {
  const text = [
    "==> building",
    "some unrelated line",
    "dyld[42]: Symbol not found: _bar",
    "Trace/BPT trap: 5",
  ].join("\n");
  const line = detectDyldLaunchFailure(text);
  assert.equal(line, "dyld[42]: Symbol not found: _bar");
});

test("当たる: 行頭でなくてもよい(ラベル付きログに混ざる形)", () => {
  const line = detectDyldLaunchFailure("[fleetest stderr] dyld[9]: Library not loaded: @rpath/liby.dylib");
  assert.equal(line, "[fleetest stderr] dyld[9]: Library not loaded: @rpath/liby.dylib");
});

test("当たる: 長い行は300文字程度で切り詰める", () => {
  const symbol = "_$s".padEnd(400, "x");
  const text = `dyld[1]: Symbol not found: ${symbol}`;
  const line = detectDyldLaunchFailure(text);
  assert.ok(line !== null);
  assert.ok(line.endsWith("…"));
  // 末尾の "…" を除いた本体が 300 文字ちょうど。
  assert.equal(line.length - 1, 300);
});

test("当たらない: 普通のエラー文言", () => {
  assert.equal(detectDyldLaunchFailure("Error: scenario not found"), null);
});

test("当たらない: dyld を含むが読み込み失敗ではない文言", () => {
  assert.equal(detectDyldLaunchFailure("dyld: warning: could not resolve DYLD_INSERT_LIBRARIES"), null);
});

test("当たらない: 空文字列", () => {
  assert.equal(detectDyldLaunchFailure(""), null);
});

test("DyldNotifyGate: 最初の claim() だけ true を返す", () => {
  const gate = new DyldNotifyGate();
  assert.equal(gate.claim(), true);
  assert.equal(gate.claim(), false);
  assert.equal(gate.claim(), false);
});

test("DyldNotifyGate: 別インスタンスは互いに独立", () => {
  const a = new DyldNotifyGate();
  const b = new DyldNotifyGate();
  assert.equal(a.claim(), true);
  assert.equal(b.claim(), true);
});
