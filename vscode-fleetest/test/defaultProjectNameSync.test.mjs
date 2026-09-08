// 既定プロジェクト名が Swift(CLI/MCP の省略時解決)と拡張(初期選択・起動時の作成)で一致する
// ことの検証。ズレると拡張が作った器を CLI が既定として選ばない(選ばれるのは別名の方)。
//
// 同期相手:
//   Sources/FTCore/TestProject.swift            ProjectStore.defaultProjectName
//   vscode-fleetest/src/projectResolution.ts    DEFAULT_PROJECT_NAME
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

test("既定プロジェクト名が Swift と拡張で一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/TestProject.swift"), "utf8");
  const swiftMatch = swift.match(/static let defaultProjectName = "([^"]+)"/);
  assert.ok(swiftMatch, "TestProject.swift から defaultProjectName を抽出できません");

  const ts = readFileSync(path.join(ROOT, "src/projectResolution.ts"), "utf8");
  const tsMatch = ts.match(/export const DEFAULT_PROJECT_NAME = "([^"]+)"/);
  assert.ok(tsMatch, "projectResolution.ts から DEFAULT_PROJECT_NAME を抽出できません");

  assert.equal(tsMatch[1], swiftMatch[1]);
  assert.equal(swiftMatch[1], "default", "既定名はリテラルで固定する");
});
