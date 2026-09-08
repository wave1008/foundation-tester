// テストプロジェクト名の文字規則が Swift(SPM ターゲット名の検証)と拡張(新規/コピー先/リネーム後の
// 名前検証)で一致することの検証。ズレると拡張が通した名前を CLI の `project create` 等が拒否する
// (または逆に拡張が弾くべき名前を通す)。
//
// 同期相手:
//   Sources/FTCore/TestProject.swift            ProjectStore.isValidName
//   vscode-fleetest/src/monitorProfileForms.ts  PROJECT_NAME_PATTERN
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

test("テストプロジェクト名の正規表現が Swift と拡張で一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/TestProject.swift"), "utf8");
  const swiftMatch = swift.match(/name\.range\(of: "([^"]+)", options: \.regularExpression\)/);
  assert.ok(swiftMatch, "TestProject.swift から isValidName の正規表現を抽出できません");

  const ts = readFileSync(path.join(ROOT, "src/monitorProfileForms.ts"), "utf8");
  const tsMatch = ts.match(/const PROJECT_NAME_PATTERN = \/(.+)\/;/);
  assert.ok(tsMatch, "monitorProfileForms.ts から PROJECT_NAME_PATTERN を抽出できません");

  assert.equal(tsMatch[1], swiftMatch[1]);
  assert.equal(swiftMatch[1], "^[A-Za-z0-9_][A-Za-z0-9_-]*$", "規則はリテラルで固定する");
});
