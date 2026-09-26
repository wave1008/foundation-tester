// dashboardOpenSourceValidation.test.mjs
// (失敗ステップの file:line クリックでエディタを開く)のホスト側検証
// (resolveWorkspaceRelativeFile。monitorDashboardController.ts の handleOpenReport/handleOpenSource が
// 共有する)。vscode API には触れない純関数なので、esbuild.mjs の vscode スタブ経由で直接 import できる。

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";

import { resolveWorkspaceRelativeFile } from "../src/monitorDashboardController";

const ROOT = path.sep === "/" ? "/ws" : "C:\\ws";

test("resolveWorkspaceRelativeFile: workspaceRoot 配下の相対パス+拡張子一致は解決される", () => {
  const resolved = resolveWorkspaceRelativeFile(ROOT, "TestProjects/E2E-CMP/scenarios/x.swift", ".swift");
  assert.equal(resolved, path.join(ROOT, "TestProjects/E2E-CMP/scenarios/x.swift"));
});

test("resolveWorkspaceRelativeFile: workspaceRoot 自身の配下(絶対パスで渡された場合)も解決される", () => {
  const abs = path.join(ROOT, "a.swift");
  assert.equal(resolveWorkspaceRelativeFile(ROOT, abs, ".swift"), abs);
});

test("resolveWorkspaceRelativeFile: 配下でない(.. で外へ出る)パスは拒否する", () => {
  assert.equal(resolveWorkspaceRelativeFile(ROOT, "../outside.swift", ".swift"), null);
  assert.equal(resolveWorkspaceRelativeFile(ROOT, "../../etc/passwd", ".swift"), null);
});

test("resolveWorkspaceRelativeFile: 配下でない絶対パスは拒否する", () => {
  const outside = path.sep === "/" ? "/etc/passwd" : "C:\\other\\a.swift";
  assert.equal(resolveWorkspaceRelativeFile(ROOT, outside, ".swift"), null);
});

test("resolveWorkspaceRelativeFile: 拡張子が要求と違えば拒否する(.md を渡して .swift を要求)", () => {
  assert.equal(resolveWorkspaceRelativeFile(ROOT, "reports/x.md", ".swift"), null);
});

test("resolveWorkspaceRelativeFile: 拡張子が一致すれば .md 要求でも解決される(handleOpenReport 側の使い方)", () => {
  const resolved = resolveWorkspaceRelativeFile(ROOT, "results/reports/x.md", ".md");
  assert.equal(resolved, path.join(ROOT, "results/reports/x.md"));
});

test("resolveWorkspaceRelativeFile: workspaceRoot と同名で始まるだけの兄弟ディレクトリは配下と誤認しない", () => {
  // ROOT = "/ws" のとき "/ws-evil/x.swift" は前方一致するが配下ではない(path.sep 境界で切る)
  const sibling = ROOT + "-evil" + path.sep + "x.swift";
  assert.equal(resolveWorkspaceRelativeFile(ROOT, sibling, ".swift"), null);
});
