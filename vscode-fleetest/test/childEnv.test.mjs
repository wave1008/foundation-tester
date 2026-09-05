// childEnv.test.mjs
// src/childEnv.ts の単体テスト。esbuild が "../src/childEnv" を .ts に解決してバンドルする
// (他の *.test.mjs と同じ方針)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { PARENT_PID_ENV, childEnv } from "../src/childEnv";

test("childEnv: FT_PARENT_PID は process.pid の文字列", () => {
  const env = childEnv();
  assert.equal(env[PARENT_PID_ENV], String(process.pid));
});

test("childEnv: 既存の process.env を保つ", () => {
  const marker = "__childEnv_test_marker__";
  process.env[marker] = "1";
  try {
    const env = childEnv();
    assert.equal(env[marker], "1");
  } finally {
    delete process.env[marker];
  }
});

test("childEnv: extra を保ちつつ FT_PARENT_PID で上書きする", () => {
  const env = childEnv({ FOO: "bar", [PARENT_PID_ENV]: "bogus" });
  assert.equal(env.FOO, "bar");
  assert.equal(env[PARENT_PID_ENV], String(process.pid), "extra に誤った値があっても親 pid を優先する");
});
