// reportCodeLens.test.mjs
// computeFailedLensEntries(vscode 非依存の純粋関数)の回帰テスト。registerReportCodeLens 本体は
// vscode.TestController/languages.registerCodeLensProvider 等が要るためテスト対象外
// (runHandler.test.mjs 冒頭コメント参照)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { computeFailedLensEntries } from "../src/reportCodeLens";

const uriA = "file:///A.swift";
const uriB = "file:///B.swift";

test("computeFailedLensEntries: 対象ドキュメントの failed leaf のみ返す", () => {
  const leaves = [
    { id: "A.s1", uriKey: uriA, line: 10 },
    { id: "A.s2", uriKey: uriA, line: 20 },
    { id: "B.s1", uriKey: uriB, line: 5 },
  ];
  const results = new Map([
    ["A.s1", "failed"],
    ["A.s2", "passed"],
    ["B.s1", "failed"],
  ]);
  const entries = computeFailedLensEntries(leaves, uriA, results);
  assert.deepEqual(entries, [{ id: "A.s1", line: 10 }]);
});

test("computeFailedLensEntries: 結果ストアに無い leaf は含めない", () => {
  const leaves = [{ id: "A.s1", uriKey: uriA, line: 10 }];
  const entries = computeFailedLensEntries(leaves, uriA, new Map());
  assert.deepEqual(entries, []);
});

test("computeFailedLensEntries: leaf.id が NFD でも結果ストア(NFC)と一致する", () => {
  // readAllResults はファイル名を NFC 正規化して返す(lastResults.ts)。leaf.id 側が万一 NFD でも
  // lookupKey が NFC 正規化してから引くため一致する。
  const nfcId = "デモ_Android時計.S0010";
  const leaves = [{ id: nfcId.normalize("NFD"), uriKey: uriA, line: 3 }];
  const results = new Map([[nfcId, "failed"]]);
  const entries = computeFailedLensEntries(leaves, uriA, results);
  assert.deepEqual(entries, [{ id: nfcId.normalize("NFD"), line: 3 }]);
});

test("computeFailedLensEntries: passed 状態は含めない", () => {
  const leaves = [{ id: "A.s1", uriKey: uriA, line: 10 }];
  const results = new Map([["A.s1", "passed"]]);
  assert.deepEqual(computeFailedLensEntries(leaves, uriA, results), []);
});
