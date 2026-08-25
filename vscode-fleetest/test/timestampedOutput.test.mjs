// timestampedOutput.test.mjs
// OUTPUT 全行への時刻前置(src/timestampedOutput.ts)の回帰テスト。node:test。
// 時刻は注入した now() から作るので実時刻に依存しない。

import assert from "node:assert/strict";
import { test } from "node:test";
import { createTimestampedAppender } from "../src/timestampedOutput";

function harness(times) {
  const lines = [];
  let i = 0;
  const append = createTimestampedAppender({ appendLine: (line) => lines.push(line) }, () => times[i++]);
  return { lines, append };
}

test("各行に HH:mm:ss が前置される", () => {
  const h = harness([new Date(2026, 7, 24, 13, 15, 20)]);
  h.append("[monitor] プロセスが終了しました(exit code: null / signal: SIGKILL)");
  assert.equal(h.lines.at(-1), "13:15:20 [monitor] プロセスが終了しました(exit code: null / signal: SIGKILL)");
});

test("時・分・秒は 0 詰めされる(1桁でも桁が揃う)", () => {
  const h = harness([new Date(2026, 7, 24, 9, 5, 3)]);
  h.append("x");
  assert.equal(h.lines.at(-1), "09:05:03 x");
});

test("初回は日付の区切り行が先に出る(先頭を見れば何日の記録か分かる)", () => {
  const h = harness([new Date(2026, 7, 24, 13, 15, 20)]);
  h.append("first");
  assert.deepEqual(h.lines, ["──── 2026-08-24 ────", "13:15:20 first"]);
});

test("同じ日のうちは日付行を繰り返さない", () => {
  const h = harness([new Date(2026, 7, 24, 13, 15, 20), new Date(2026, 7, 24, 15, 47, 1)]);
  h.append("a");
  h.append("b");
  assert.deepEqual(h.lines, ["──── 2026-08-24 ────", "13:15:20 a", "15:47:01 b"]);
});

test("日付が変わったらそこで日付行を挟む(日をまたいだ開きっぱなしでも時刻が曖昧にならない)", () => {
  const h = harness([new Date(2026, 7, 24, 23, 59, 59), new Date(2026, 7, 25, 0, 0, 1)]);
  h.append("before");
  h.append("after");
  assert.deepEqual(h.lines, [
    "──── 2026-08-24 ────",
    "23:59:59 before",
    "──── 2026-08-25 ────",
    "00:00:01 after",
  ]);
});
