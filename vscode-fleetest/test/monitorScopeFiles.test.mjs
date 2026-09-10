import assert from "node:assert/strict";
import { test } from "node:test";
import { monitorRestartNeeded, runProfileNeedsRestart, runProfileScopeChanged, runProfileScopeKey } from "../src/monitorScopeFiles";

test("machine profile changes always restart the monitor", () => {
  assert.equal(monitorRestartNeeded("machine", "local", ""), true);
  assert.equal(monitorRestartNeeded("machine", "other", "ios-basic"), true);
});

test("run profile changes restart only for the selected profile", () => {
  assert.equal(monitorRestartNeeded("run", "ios-basic", "ios-basic"), true);
  assert.equal(monitorRestartNeeded("run", "android", "ios-basic"), false);
  assert.equal(monitorRestartNeeded("run", "ios-basic", ""), false);
});

// プロファイル画面は1操作ごとに自動保存するので、monitor が読まない欄(FM のトグル等)の変更で
// 配信を張り直さない。monitor が読むのは machine と devices だけ(ApiMonitorCommand.swift)
test("run profile scope key only reflects machine and devices", () => {
  const base = { machine: "M1", app: "a", devices: [{ name: "s1" }], heal: true, defaultTimeout: 5 };
  const key = runProfileScopeKey(JSON.stringify(base));
  assert.equal(runProfileScopeKey(JSON.stringify({ ...base, heal: false, defaultTimeout: 8, app: "b" })), key);
  assert.notEqual(runProfileScopeKey(JSON.stringify({ ...base, machine: "M2" })), key);
  assert.notEqual(runProfileScopeKey(JSON.stringify({ ...base, devices: [{ name: "s1", machine: "M1Max" }] })), key);
  assert.notEqual(runProfileScopeKey(JSON.stringify({ ...base, devices: [] })), key);
  assert.equal(runProfileScopeKey("{not json"), null);
  assert.equal(runProfileScopeKey("[]"), null);
});

test("run profile change restarts unless the scope is known and unchanged", () => {
  assert.equal(runProfileScopeChanged("k", "k"), false);
  assert.equal(runProfileScopeChanged("k", "k2"), true);
  assert.equal(runProfileScopeChanged(undefined, "k"), true, "初見は判定できないので再起動する");
  assert.equal(runProfileScopeChanged("k", null), true, "読めないときは再起動する");
});

test("hand edits always restart; form saves restart only on scope change or right after a hand edit", () => {
  const change = (fromForm, editedOutsideBefore, previousKey, nextKey) =>
    runProfileNeedsRestart({ fromForm, editedOutsideBefore, previousKey, nextKey });
  assert.equal(change(true, false, "k", "k"), false, "フォームの保存で machine/devices が同じなら再起動しない");
  assert.equal(change(true, false, "k", "k2"), true);
  // monitor は全キーをデコードするので、手で直した無関係な欄でも復旧に再起動が要る
  assert.equal(change(false, false, "k", "k"), true, "手編集はスコープが同じでも再起動する");
  assert.equal(change(true, true, "k", "k"), true, "手編集の後の最初のフォーム保存は再起動する");
});
