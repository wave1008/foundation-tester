import assert from "node:assert/strict";
import { test } from "node:test";
import { monitorRestartNeeded } from "../src/monitorScopeFiles";

test("machine profile changes always restart the monitor", () => {
  assert.equal(monitorRestartNeeded("machine", "local", ""), true);
  assert.equal(monitorRestartNeeded("machine", "other", "ios-basic"), true);
});

test("run profile changes restart only for the selected profile", () => {
  assert.equal(monitorRestartNeeded("run", "ios-basic", "ios-basic"), true);
  assert.equal(monitorRestartNeeded("run", "android", "ios-basic"), false);
  assert.equal(monitorRestartNeeded("run", "ios-basic", ""), false);
});
