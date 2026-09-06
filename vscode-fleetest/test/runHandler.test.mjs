// runHandler.test.mjs
// lastResults.ts のヘルパー(lastResultsDir/readFailedScenarioIds/readAllResults)と、
// runHandler.ts の resolveTargets(request.include/exclude → 対象 leaf)の回帰テスト。
// node:test。executeRun 本体は vscode.TestRun/TestItem の実装が要るため(vscode-stub は空 Proxy)
// テスト対象外(esbuild.mjs 参照)。TestItem は最小の duck type(id/children/tags)で作る。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { lastResultsDir, lookupKey, readAllResults, readFailedScenarioIds } from "../src/lastResults";
import { resolveTargets } from "../src/runHandler";
import { classId, DELETED_TAG_ID, folderId } from "../src/testTree";

/** vscode.TestItemCollection の最小 duck type(size / forEach)。 */
function collection(items) {
  return { size: items.length, forEach: (fn) => items.forEach((item) => fn(item)) };
}
function item(id, children = [], tags = []) {
  return { id, children: collection(children), tags };
}
function controllerWith(...roots) {
  return { items: collection(roots) };
}

function makeStateDir(entries) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-last-results-test-"));
  for (const [name, content] of Object.entries(entries)) {
    fs.writeFileSync(path.join(dir, name), content, "utf8");
  }
  return dir;
}

test("lastResultsDir: workspaceRoot/.fleetest/last-results/<project> を返す", () => {
  assert.equal(
    lastResultsDir("/repo", "SampleApp"),
    path.join("/repo", ".fleetest", "last-results", "SampleApp"),
  );
});

test("readFailedScenarioIds: 内容が failed のファイル名だけを集合として返す", () => {
  const dir = makeStateDir({
    "クラスA.成功シナリオ": "passed",
    "クラスA.失敗シナリオ": "failed",
    "クラスB.失敗シナリオ2": "failed",
  });
  const ids = readFailedScenarioIds(dir);
  assert.deepEqual([...ids].sort(), ["クラスA.失敗シナリオ", "クラスB.失敗シナリオ2"].sort());
});

test("readFailedScenarioIds: ディレクトリが無ければ空集合", () => {
  const missing = path.join(os.tmpdir(), "fleetest-last-results-missing-", String(Date.now()));
  assert.deepEqual(readFailedScenarioIds(missing), new Set());
});

test("readFailedScenarioIds: NFD ファイル名でも NFC の id で照合できる(macOS readdir 対策)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-nfd-"));
  try {
    const nfcId = "デモ_Android時計.S0010";
    fs.writeFileSync(path.join(dir, nfcId.normalize("NFD")), "failed");
    const ids = readFailedScenarioIds(dir);
    assert.equal(ids.has(lookupKey(nfcId)), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("readAllResults: passed/failed をファイル名→状態の Map として返す", () => {
  const dir = makeStateDir({
    "クラスA.成功シナリオ": "passed",
    "クラスA.失敗シナリオ": "failed",
  });
  const results = readAllResults(dir);
  assert.deepEqual(
    [...results].sort(),
    [
      ["クラスA.成功シナリオ", "passed"],
      ["クラスA.失敗シナリオ", "failed"],
    ].sort(),
  );
});

test("readAllResults: ディレクトリが無ければ空 Map", () => {
  const missing = path.join(os.tmpdir(), "fleetest-last-results-missing-", String(Date.now()));
  assert.deepEqual(readAllResults(missing), new Map());
});

test("readAllResults: NFD ファイル名は NFC キーで格納される", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-nfd-"));
  try {
    const nfcId = "デモ_Android時計.S0010";
    fs.writeFileSync(path.join(dir, nfcId.normalize("NFD")), "passed");
    const results = readAllResults(dir);
    assert.equal(results.get(lookupKey(nfcId)), "passed");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("readAllResults: passed/failed 以外の内容のファイルはスキップする", () => {
  const dir = makeStateDir({
    "クラスA.成功シナリオ": "passed",
    "クラスA.壊れたファイル": "garbage",
  });
  const results = readAllResults(dir);
  assert.deepEqual([...results.keys()], ["クラスA.成功シナリオ"]);
});

// ---- resolveTargets ----
// 空クラス(@Test なし。list-scenarios の emptyClasses)は testTree.ts が子の無い class ノードとして
// 出す。children.size === 0 を leaf の根拠にすると `class:<folder>/<Class>` が --scenario として CLI に
// 渡り、run 全体が「scenario not found」で落ちる(「Run All」が1つの空クラスで丸ごと赤になる)。

test("resolveTargets: 空クラスの class ノードは include 未指定(Run All)でも対象に入らない", () => {
  const leaf = item("Login.S0010");
  const tree = controllerWith(
    item(folderId("smoke"), [item(classId("smoke", "Login"), [leaf])]),
    item(classId(null, "EmptyClass")),
  );
  const targets = resolveTargets(tree, { include: undefined, exclude: undefined });
  assert.deepEqual([...targets.keys()], ["Login.S0010"]);
});

test("resolveTargets: 空クラスを明示 include しても対象 0 件(class id を --scenario に渡さない)", () => {
  const empty = item(classId("smoke", "EmptyClass"));
  const tree = controllerWith(item(folderId("smoke"), [empty]));
  const targets = resolveTargets(tree, { include: [empty], exclude: undefined });
  assert.equal(targets.size, 0);
});

test("resolveTargets: class を明示 include すると配下 leaf に展開し、@Deleted は除外する", () => {
  const live = item("Login.S0010");
  const deleted = item("Login.S0020", [], [{ id: DELETED_TAG_ID }]);
  const cls = item(classId(null, "Login"), [live, deleted]);
  const targets = resolveTargets(controllerWith(cls), { include: [cls], exclude: undefined });
  assert.deepEqual([...targets.keys()], ["Login.S0010"]);
});

test("resolveTargets: leaf を明示 include すると @Deleted でも対象にする", () => {
  const deleted = item("Login.S0020", [], [{ id: DELETED_TAG_ID }]);
  const tree = controllerWith(item(classId(null, "Login"), [deleted]));
  const targets = resolveTargets(tree, { include: [deleted], exclude: undefined });
  assert.deepEqual([...targets.keys()], ["Login.S0020"]);
});

test("resolveTargets: exclude に class を渡すと配下 leaf を丸ごと外し、空クラスの exclude は何もしない", () => {
  const a = item("A.S0010");
  const b = item("B.S0010");
  const clsA = item(classId(null, "A"), [a]);
  const clsB = item(classId(null, "B"), [b]);
  const empty = item(classId(null, "Empty"));
  const tree = controllerWith(clsA, clsB, empty);
  const targets = resolveTargets(tree, { include: undefined, exclude: [clsA, empty] });
  assert.deepEqual([...targets.keys()], ["B.S0010"]);
});
