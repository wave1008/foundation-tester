// projectResolution.test.mjs
// 対象プロジェクトの解決規則(src/projectResolution.ts)。設定 > 1件 > `project1` > none/ambiguous。
import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_PROJECT_NAME, resolveProjectFrom } from "../src/projectResolution";

test("設定値が候補にあればそれ(前後の空白は落とす)", () => {
  assert.deepEqual(resolveProjectFrom(" MyApp ", ["project1", "MyApp"]),
    { kind: "resolved", project: "MyApp" });
});

test("設定値が候補に無ければ missing(存在確認せず採用しない)", () => {
  const candidates = ["project1", "Other"];
  const resolution = resolveProjectFrom(" MyApp ", candidates);
  assert.deepEqual(resolution, { kind: "missing", project: "MyApp", candidates: ["project1", "Other"] });
});

test("設定値が非空でも候補が0件なら missing(候補は空配列)", () => {
  assert.deepEqual(resolveProjectFrom("MyApp", []), { kind: "missing", project: "MyApp", candidates: [] });
});

test("候補が1件ならそれ(名前が project1 でなくても)", () => {
  assert.deepEqual(resolveProjectFrom("", ["Only"]), { kind: "resolved", project: "Only" });
});

test("候補が無ければ none", () => {
  assert.deepEqual(resolveProjectFrom("", []), { kind: "none" });
});

test("複数あって project1 が居ればそれを初期選択にする", () => {
  assert.equal(DEFAULT_PROJECT_NAME, "project1");
  assert.deepEqual(resolveProjectFrom("", ["Alpha", "project1", "Beta"]),
    { kind: "resolved", project: "project1" });
});

test("複数あって project1 が居なければ ambiguous(候補は渡した順のコピー)", () => {
  const candidates = ["Alpha", "Beta"];
  const resolution = resolveProjectFrom("", candidates);
  assert.deepEqual(resolution, { kind: "ambiguous", candidates: ["Alpha", "Beta"] });
  assert.notEqual(resolution.candidates, candidates);
});
