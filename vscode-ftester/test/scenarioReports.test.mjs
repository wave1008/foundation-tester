// scenarioReports.test.mjs
// findLatestReport/listRecentReports(src/scenarioReports.ts、vscode 非依存)の回帰テスト。
// 実ファイルシステム(mkdtempSync)上で検証する(monitorDeviceOps.test.mjs と同じパターン)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { findLatestReport, listRecentReports, reportsDir } from "../src/scenarioReports";

function makeDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "ftester-scenarioreports-test-"));
}

test("reportsDir: workspaceRoot/Projects/<project>/reports を返す", () => {
  assert.equal(reportsDir("/root", "P"), path.join("/root", "Projects", "P", "reports"));
});

test("findLatestReport: 同一シナリオの複数レポートから最新(タイムスタンプ最大)を選ぶ", () => {
  const dir = makeDir();
  try {
    fs.writeFileSync(path.join(dir, "scenario-20260716-090000-000-Demo_S0001.md"), "");
    fs.writeFileSync(path.join(dir, "scenario-20260716-120000-000-Demo_S0001.md"), "");
    fs.writeFileSync(path.join(dir, "scenario-20260715-235959-999-Demo_S0001.md"), "");
    const found = findLatestReport(dir, "Demo.S0001");
    assert.equal(found, path.join(dir, "scenario-20260716-120000-000-Demo_S0001.md"));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("findLatestReport: readdirSync が NFD で返すファイル名でも NFC のシナリオIDで見つかる", () => {
  const dir = makeDir();
  try {
    // "が"(NFC, U+304C)は "か"(U+304B)+ 濁点(U+3099)の NFD 形にも分解できる。
    const scenarioId = "デモ_iOS設定".normalize("NFC") + ".S0030";
    const fileName = "scenario-20260716-120000-000-デモ_iOS設定_S0030.md".normalize("NFD");
    fs.writeFileSync(path.join(dir, fileName), "");
    const found = findLatestReport(dir, scenarioId);
    assert.ok(found, "NFD ファイル名が NFC シナリオIDで見つかること");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("findLatestReport: ディレクトリが存在しなければ undefined", () => {
  assert.equal(findLatestReport(path.join(os.tmpdir(), "no-such-dir-xyz"), "Demo.S0001"), undefined);
});

test("listRecentReports: ディレクトリが存在しなければ空配列", () => {
  assert.deepEqual(
    listRecentReports(path.join(os.tmpdir(), "no-such-dir-xyz"), new Set(["Demo.S0001"])),
    [],
  );
});

test("findLatestReport: 別シナリオ/プレフィックス不一致のファイルは無視する", () => {
  const dir = makeDir();
  try {
    fs.writeFileSync(path.join(dir, "scenario-20260716-120000-000-Other_S0001.md"), "");
    fs.writeFileSync(path.join(dir, "not-a-report.md"), "");
    fs.writeFileSync(path.join(dir, "scenario-20260716-120000-000-Demo_S0001.txt"), "");
    assert.equal(findLatestReport(dir, "Demo.S0001"), undefined);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("findLatestReport: クラス名自体に underscore を含むシナリオIDのドット→underscore変換", () => {
  const dir = makeDir();
  try {
    fs.writeFileSync(path.join(dir, "scenario-20260716-120000-000-デモ_iOS設定_S0030.md"), "");
    const found = findLatestReport(dir, "デモ_iOS設定.S0030");
    assert.equal(found, path.join(dir, "scenario-20260716-120000-000-デモ_iOS設定_S0030.md"));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("listRecentReports: 複数シナリオを新しい順(ファイル名降順)に返す", () => {
  const dir = makeDir();
  try {
    fs.writeFileSync(path.join(dir, "scenario-20260716-090000-000-A_S0001.md"), "");
    fs.writeFileSync(path.join(dir, "scenario-20260716-150000-000-B_S0001.md"), "");
    const results = listRecentReports(dir, new Set(["A.S0001", "B.S0001", "C.S0001"]));
    assert.deepEqual(
      results.map((r) => r.scenarioId),
      ["B.S0001", "A.S0001"],
    );
    assert.equal(results[0].fileName, "scenario-20260716-150000-000-B_S0001.md");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
