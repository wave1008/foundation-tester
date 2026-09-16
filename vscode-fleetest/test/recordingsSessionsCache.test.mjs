// recordingsSessionsCache.test.mjs
// テストセッション一覧の前回結果を workspaceState に置く(src/recordingsSessionsCache.ts)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { workspaceRecordingsSessionsCache } from "../src/recordingsSessionsCache";

function memento(initial = {}) {
  const values = new Map(Object.entries(initial));
  return { get: (key) => values.get(key), update: async (key, value) => void values.set(key, value), values };
}

test("鍵ごとに保存して読み戻す(他の鍵は消さない)", () => {
  const state = memento();
  const cache = workspaceRecordingsSessionsCache(state);
  cache.set("AppA", [{ project: "AppA", runID: "r1" }]);
  cache.set("AppB", [{ project: "AppB", runID: "r2" }]);
  assert.deepEqual(cache.get("AppA"), [{ project: "AppA", runID: "r1" }]);
  assert.deepEqual(cache.get("AppB"), [{ project: "AppB", runID: "r2" }]);
  assert.equal(cache.get("AppC"), undefined);
});

test("版の違う控え・壊れた控えは読まない", () => {
  const old = workspaceRecordingsSessionsCache(memento({
    "monitor.recordingsSessionsCache": { version: 0, entries: { AppA: [{ project: "AppA", runID: "r1" }] } },
  }));
  assert.equal(old.get("AppA"), undefined);
  const broken = workspaceRecordingsSessionsCache(memento({
    "monitor.recordingsSessionsCache": { version: 1, entries: { AppA: [{ runID: 3 }], AppB: "x" } },
  }));
  assert.equal(broken.get("AppA"), undefined);
  assert.equal(broken.get("AppB"), undefined);
});
