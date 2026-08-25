// copyTestName.test.mjs
// resolveEntryAtCursor(vscode 非依存の純粋関数)の回帰テスト。runHandler.ts 内の command handler
// 本体は vscode.TestItem/activeTextEditor 等が要るためテスト対象外(runHandler.test.mjs 冒頭コメント参照)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveEntryAtCursor, truncateForStatusBar } from "../src/copyTestName";

const uriA = "file:///A.swift";
const uriB = "file:///B.swift";

test("resolveEntryAtCursor: 同一行の完全一致では depth が高い(より深い)エントリが勝つ", () => {
  const entries = [
    { id: "class:/A", label: "A", uriKey: uriA, startLine: 10, depth: 1 },
    { id: "A.s1", label: "s1", uriKey: uriA, startLine: 10, depth: 2 },
  ];
  const resolved = resolveEntryAtCursor(entries, { uriKey: uriA, line: 10 });
  assert.equal(resolved?.id, "A.s1");
});

test("resolveEntryAtCursor: 完全一致が無ければ直前(startLine <= line)の最大値にフォールバックする", () => {
  const entries = [
    { id: "class:/A", label: "A", uriKey: uriA, startLine: 5, depth: 1 },
    { id: "A.s1", label: "s1", uriKey: uriA, startLine: 8, depth: 2 },
    { id: "A.s2", label: "s2", uriKey: uriA, startLine: 20, depth: 2 },
  ];
  const resolved = resolveEntryAtCursor(entries, { uriKey: uriA, line: 15 });
  assert.equal(resolved?.id, "A.s1");
});

test("resolveEntryAtCursor: フォールバックのタイでも depth が高い方が勝つ", () => {
  const entries = [
    { id: "class:/A", label: "A", uriKey: uriA, startLine: 8, depth: 1 },
    { id: "A.s1", label: "s1", uriKey: uriA, startLine: 8, depth: 2 },
  ];
  const resolved = resolveEntryAtCursor(entries, { uriKey: uriA, line: 15 });
  assert.equal(resolved?.id, "A.s1");
});

test("resolveEntryAtCursor: 別 uri のエントリは行が一致/直前でも除外する", () => {
  const entries = [
    { id: "B.s1", label: "s1", uriKey: uriB, startLine: 10, depth: 2 },
  ];
  const resolved = resolveEntryAtCursor(entries, { uriKey: uriA, line: 10 });
  assert.equal(resolved, undefined);
});

test("resolveEntryAtCursor: entries が空なら undefined", () => {
  assert.equal(resolveEntryAtCursor([], { uriKey: uriA, line: 0 }), undefined);
});

test("resolveEntryAtCursor: 同一 uri に startLine <= line の候補が無ければ undefined", () => {
  const entries = [
    { id: "A.s1", label: "s1", uriKey: uriA, startLine: 20, depth: 2 },
  ];
  const resolved = resolveEntryAtCursor(entries, { uriKey: uriA, line: 5 });
  assert.equal(resolved, undefined);
});

test("truncateForStatusBar: maxLen 以下ならそのまま返す", () => {
  assert.equal(truncateForStatusBar("short", 50), "short");
});

test("truncateForStatusBar: maxLen 超過分は省略記号付きで切り詰める", () => {
  const text = "a".repeat(60);
  const truncated = truncateForStatusBar(text, 50);
  assert.equal(truncated, `${"a".repeat(50)}…`);
});
