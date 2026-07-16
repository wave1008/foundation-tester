// runHandler.test.mjs
// lastResults.ts のヘルパー(lastResultsDir/readFailedScenarioIds)の回帰テスト。
// node:test。executeRun 本体は vscode.TestRun/TestItem の実装が要るため(vscode-stub は空 Proxy)、
// この2関数はどちらも vscode を呼ばない純粋な fs 読み取りのみなのでテスト可能(esbuild.mjs 参照)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { lastResultsDir, lookupKey, readFailedScenarioIds } from "../src/lastResults";

function makeStateDir(entries) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-last-results-test-"));
  for (const [name, content] of Object.entries(entries)) {
    fs.writeFileSync(path.join(dir, name), content, "utf8");
  }
  return dir;
}

test("lastResultsDir: workspaceRoot/.ftester/last-results/<project> を返す", () => {
  assert.equal(
    lastResultsDir("/repo", "SampleApp"),
    path.join("/repo", ".ftester", "last-results", "SampleApp"),
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
  const missing = path.join(os.tmpdir(), "ftester-last-results-missing-", String(Date.now()));
  assert.deepEqual(readFailedScenarioIds(missing), new Set());
});

test("readFailedScenarioIds: NFD ファイル名でも NFC の id で照合できる(macOS readdir 対策)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-nfd-"));
  try {
    const nfcId = "デモ_Android時計.S0010";
    fs.writeFileSync(path.join(dir, nfcId.normalize("NFD")), "failed");
    const ids = readFailedScenarioIds(dir);
    assert.equal(ids.has(lookupKey(nfcId)), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
