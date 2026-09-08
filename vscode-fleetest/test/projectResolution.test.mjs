// projectResolution.test.mjs
// 対象プロジェクトの解決規則(src/projectResolution.ts)。設定 > 1件 > `default` > none/ambiguous。
import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_PROJECT_NAME, resolveProjectFrom } from "../src/projectResolution";

test("設定値があれば候補に関係なくそれ(前後の空白は落とす)", () => {
  assert.deepEqual(resolveProjectFrom(" MyApp ", ["default", "Other"]),
    { kind: "resolved", project: "MyApp" });
});

test("候補が1件ならそれ(名前が default でなくても)", () => {
  assert.deepEqual(resolveProjectFrom("", ["Only"]), { kind: "resolved", project: "Only" });
});

test("候補が無ければ none", () => {
  assert.deepEqual(resolveProjectFrom("", []), { kind: "none" });
});

test("複数あって default が居ればそれを初期選択にする", () => {
  assert.equal(DEFAULT_PROJECT_NAME, "default");
  assert.deepEqual(resolveProjectFrom("", ["Alpha", "default", "Beta"]),
    { kind: "resolved", project: "default" });
});

test("複数あって default が居なければ ambiguous(候補は渡した順のコピー)", () => {
  const candidates = ["Alpha", "Beta"];
  const resolution = resolveProjectFrom("", candidates);
  assert.deepEqual(resolution, { kind: "ambiguous", candidates: ["Alpha", "Beta"] });
  assert.notEqual(resolution.candidates, candidates);
});
