// deviceNaming.js(拡張の「デバイスを追加」の命名)を、Swift の VirtualDeviceNaming と共有する正解表で照合する。
// 正解表: Tests/Fixtures/VirtualDeviceNaming/cases.json(Swift 側は VirtualDeviceNamingTests が同じ JSON を読む)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { baseName, nextUnusedNames } from "../src/webview/monitor/deviceNaming.js";

const cases = JSON.parse(
  readFileSync(new URL("../../Tests/Fixtures/VirtualDeviceNaming/cases.json", import.meta.url), "utf8"),
);

test("baseName は正解表と一致する", () => {
  assert.ok(cases.baseName.length > 0);
  for (const c of cases.baseName) {
    assert.equal(baseName(c.model, c.osLabel), c.expected, JSON.stringify(c));
  }
});

test("nextUnusedNames は正解表と一致する", () => {
  assert.ok(cases.nextUnusedNames.length > 0);
  for (const c of cases.nextUnusedNames) {
    assert.deepEqual(nextUnusedNames(c.base, c.existing, c.count), c.expected, JSON.stringify(c).slice(0, 120));
  }
});
