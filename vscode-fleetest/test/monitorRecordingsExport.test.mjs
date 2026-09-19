// monitorRecordingsExport.test.mjs
// MonitorRecordingsController.exportSession(「テストセッション」タブの「テスト結果をエクスポート」)。
// fake-deps パターンは monitorRecordingsReveal.test.mjs と同じ。vscode 依存(保存ダイアログ・
// 情報/エラーメッセージ・OS で開く)は MonitorPanelDeps の showSaveDialog/showInfo/showError/
// openExternal 経由なので、ここでは薄いフェイクで済む。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorRecordingsController } from "../src/monitorRecordingsController";

const INDEX = {
  schemaVersion: 2,
  recordings: [
    {
      scenarioID: "クラス名.S0010",
      worker: "ios:iPhone 16",
      platform: "ios",
      file: "recordings/クラス名-S0010.mp4",
      segments: [{ startedAt: "2026-09-20T01:00:00.000Z", durationMs: 60000 }],
    },
  ],
};

const SCENARIO_RECORD = {
  schemaVersion: 1,
  runID: "20260920-010000",
  scenarioID: "クラス名.S0010",
  title: "ログインできる",
  platform: "ios",
  worker: "ios:iPhone 16",
  host: "own-host",
  profile: "own-profile",
  passed: true,
  startedAt: "2026-09-20T01:00:00.000Z",
  durationMs: 1000,
  timeline: [
    { scene: 1, sceneTitle: "ログイン画面", section: "action", index: 0, description: "tap #btn", status: "passed", at: "2026-09-20T01:00:00.500Z" },
  ],
};

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value));
}

function runDir(root, project, runID) {
  return path.join(root, "TestProjects", project, "results", "runs", `${runID.slice(0, 4)}-${runID.slice(4, 6)}`, runID);
}

function makeController(t, depsOverrides = {}) {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-recordings-export-test-"));
  t.after(() => fs.rmSync(workspaceRoot, { recursive: true, force: true }));
  const infoMessages = [];
  const errorMessages = [];
  const openedPaths = [];
  const saveDir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-recordings-export-out-"));
  t.after(() => fs.rmSync(saveDir, { recursive: true, force: true }));
  const controller = new MonitorRecordingsController({
    workspaceRoot,
    post: () => {},
    videoWebviewUri: (filePath) => `https://localhost${filePath}`,
    showSaveDialog: async (defaultAbsPath) => path.join(saveDir, path.basename(defaultAbsPath)),
    showInfo: async (message, actionLabel) => {
      infoMessages.push({ message, actionLabel });
      return undefined;
    },
    showError: (message) => errorMessages.push(message),
    openExternal: (absPath) => openedPaths.push(absPath),
    ...depsOverrides,
  });
  return { workspaceRoot, saveDir, controller, infoMessages, errorMessages, openedPaths };
}

test("exportSession: 保存先へ有効な xlsx(zip)を書き、完了メッセージを出す", async (t) => {
  const { workspaceRoot, saveDir, controller, infoMessages, errorMessages } = makeController(t);
  const dir = runDir(workspaceRoot, "SampleApp", "20260920-010000");
  writeJson(path.join(dir, "recordings", "index.json"), INDEX);
  writeJson(path.join(dir, "run.json"), { startedAt: "2026-09-20T01:00:00Z", passed: 1, failed: 0, profile: "run-profile", host: "run-host" });
  writeJson(path.join(dir, "scenarios", "クラス名.S0010.json"), SCENARIO_RECORD);

  await controller.exportSession("SampleApp", "20260920-010000");

  assert.equal(errorMessages.length, 0, errorMessages.join("\n"));
  assert.equal(infoMessages.length, 1);
  const savedPath = path.join(saveDir, "SampleApp_20260920-010000.xlsx");
  assert.ok(fs.existsSync(savedPath), "保存先にファイルができている");
  const bytes = fs.readFileSync(savedPath);
  assert.equal(bytes.readUInt32LE(0), 0x04034b50, "zip のローカルファイルヘッダ署名で始まる");
  // zip エントリ名は非圧縮で置かれる(local file header・central directory とも)ので、
  // 素朴な部分文字列探索で存在確認できる。中身(workbook.xml 等)は deflate 圧縮済みのため
  // 同じ探索は使えない(zip の詳細な検証は xlsxWriter.test.mjs / resultsExportWorkbook.test.mjs 側で行う)。
  assert.ok(bytes.includes(Buffer.from("[Content_Types].xml")), "OOXML パーツ名が入っている");
  assert.ok(bytes.includes(Buffer.from("xl/worksheets/sheet1.xml")), "概要");
  assert.ok(bytes.includes(Buffer.from("xl/worksheets/sheet2.xml")), "シナリオ");
  assert.ok(bytes.includes(Buffer.from("xl/worksheets/sheet3.xml")), "ステップ");
  // 録画があるシナリオは「シナリオ」シート(sheet2)に動画へのハイパーリンクを持つ
  // (ファイル名は zip エントリ名として非圧縮で置かれるので存在確認できる。中身の検証は
  // resultsExportWorkbook.test.mjs 側)。
  assert.ok(bytes.includes(Buffer.from("xl/worksheets/_rels/sheet2.xml.rels")), "動画リンクの rels ファイル");
});

test("exportSession: 保存ダイアログをキャンセルしたら何も書かない・メッセージも出さない", async (t) => {
  const { workspaceRoot, controller, infoMessages, errorMessages } = makeController(t, {
    showSaveDialog: async () => undefined,
  });
  const dir = runDir(workspaceRoot, "SampleApp", "20260920-010000");
  writeJson(path.join(dir, "recordings", "index.json"), INDEX);
  writeJson(path.join(dir, "run.json"), { startedAt: "2026-09-20T01:00:00Z" });
  writeJson(path.join(dir, "scenarios", "クラス名.S0010.json"), SCENARIO_RECORD);

  await controller.exportSession("SampleApp", "20260920-010000");

  assert.equal(infoMessages.length, 0);
  assert.equal(errorMessages.length, 0);
});

test("exportSession: 録画が無い(index.json 未検出)run はエラーメッセージを出す", async (t) => {
  const { controller, errorMessages, infoMessages } = makeController(t);
  await controller.exportSession("SampleApp", "20260920-020000");
  assert.equal(infoMessages.length, 0);
  assert.equal(errorMessages.length, 1);
});
