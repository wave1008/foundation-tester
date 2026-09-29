// ライブ操作の serve へ `ref: null` を送らないことの走査。
// serve(Sources/fleetest/ApiLiveCommand.swift の intField)は ref のキーがあれば整数を要求し、
// null は型違いとして操作せずに断る(省略とは読まない)。拡張が type を `ref: null` 付きで
// 送っていた間、ライブ操作の文字入力は毎回 `ref must be an integer (got null)` で失敗していた。
// 型(LiveServeCommand の ref?: number)は src の TS しか守らないので、ホスト側の全 .ts を見る。
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const SRC = path.join(process.cwd(), "src");

test("ホスト側のソースは serve へ ref: null を送らない", () => {
  const files = readdirSync(SRC).filter((name) => name.endsWith(".ts"));
  assert.ok(files.includes("monitorLiveController.ts"), "走査が src に届いていない");
  const hits = [];
  for (const name of files) {
    readFileSync(path.join(SRC, name), "utf8").split("\n").forEach((line, index) => {
      if (/\bref:\s*null\b/.test(line)) {
        hits.push(`${name}:${index + 1}: ${line.trim()}`);
      }
    });
  }
  assert.deepEqual(hits, [], "ref は省くか整数で送る(null は serve が断る)");
});
