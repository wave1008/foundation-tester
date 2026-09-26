// resultsExportWorkbook.test.mjs
// resultsExportWorkbook.ts(ResultsExportModel → xlsx)のユニットテスト。中身は自前 zip パーサで
// 読む(xlsxWriter.test.mjs と同じ手法。CRC 検証はそちら側の責務なので、ここでは省く)。

import assert from "node:assert/strict";
import { test } from "node:test";
import zlib from "node:zlib";
import { buildResultsExportWorkbook } from "../src/resultsExportWorkbook";

/** production の zip(コメント無し・非 zip64)を読み、{name: 展開済みテキスト} の Map を返す。 */
function readZip(buffer) {
  const eocd = buffer.subarray(buffer.length - 22);
  assert.equal(eocd.readUInt32LE(0), 0x06054b50);
  const totalEntries = eocd.readUInt16LE(10);
  const centralOffset = eocd.readUInt32LE(16);

  const files = new Map();
  let offset = centralOffset;
  for (let i = 0; i < totalEntries; i++) {
    assert.equal(buffer.readUInt32LE(offset), 0x02014b50, `central directory signature (entry ${i})`);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLen).toString("utf8");

    const localNameLen = buffer.readUInt16LE(localOffset + 26);
    const localExtraLen = buffer.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    const compressed = buffer.subarray(dataStart, dataStart + compressedSize);
    files.set(name, zlib.inflateRawSync(compressed).toString("utf8"));

    offset += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

function sampleModel() {
  return {
    project: "SampleApp",
    overview: {
      project: "SampleApp",
      runIDs: ["20260920-000000"],
      startedAt: "2026-09-20T00:00:00.000Z",
      finishedAt: "2026-09-20T00:10:00.000Z",
      durationSeconds: 600,
      profiles: ["p1"],
      machines: ["mac-1"],
      triggers: ["cli"],
      issuers: ["alice"],
      fmSettings: { heal: true, fmTextOcclusionCheck: true, screenLooksLike: false, ocrTextOcclusionCheck: true },
      scenarioTotal: 2, scenarioPassed: 1, scenarioFailed: 1, scenarioTimedOut: 0, scenarioInterrupted: 0, scenarioSkipped: 0,
      stepTotal: 2, stepPassed: 1, stepHealed: 0, stepPassedViaFallback: 0, stepFailed: 1, stepSkipped: 0,
    },
    classes: [
      { classID: "C", scenarioCount: 2, passedCount: 1, failedCount: 1, durationMsSum: 3000 },
    ],
    scenarios: [
      {
        scenarioID: "C.S1", className: "C", method: "S1", title: "ログインできる", platform: "ios",
        worker: "ios:iPhone 16", machine: "mac-1", result: "success", durationMs: 1000,
        startedAt: "2026-09-20T00:00:00.000Z", healedCount: 0, failedScene: null, failedSceneTitle: null,
        failedStepDescription: null, failureKind: null, reason: null, failedStepNotes: [],
        timeline: [
          { scene: 1, sceneTitle: "ログイン画面", section: "action", index: 0, description: "tap #btn", status: "passed", durationMs: 500, notes: [] },
        ],
      },
      {
        scenarioID: "C.S2", className: "C", method: "S2", title: null, platform: "android",
        worker: "android:Pixel 8", machine: "mac-1", result: "failure", durationMs: 2000,
        startedAt: "2026-09-20T00:01:00.000Z", healedCount: 0, failedScene: 1, failedSceneTitle: "ログイン画面",
        failedStepDescription: "assert", failureKind: "not-found", reason: "#btn not found", failedStepNotes: ["retry-exhausted"],
        timeline: [
          { scene: 1, sceneTitle: "ログイン画面", section: "expectation", index: 0, description: "assert", status: "failed", durationMs: null, notes: [] },
        ],
      },
    ],
  };
}

test("シート名は概要/シナリオ/ステップ(既定 locale=ja)", () => {
  const files = readZip(buildResultsExportWorkbook(sampleModel()).toBuffer());
  const wbXml = files.get("xl/workbook.xml");
  assert.match(wbXml, /<sheet name="概要"/);
  assert.match(wbXml, /<sheet name="シナリオ"/);
  assert.match(wbXml, /<sheet name="ステップ"/);
});

test("開始/終了の日付は数値セル(日付書式の numFmt)で書かれる(文字列 t=\"s\" ではない)", () => {
  const files = readZip(buildResultsExportWorkbook(sampleModel()).toBuffer());
  const styles = files.get("xl/styles.xml");
  assert.match(styles, /formatCode="yyyy\/mm\/dd hh:mm:ss"/);
  const overview = files.get("xl/worksheets/sheet1.xml");
  // B7 = 開始日時のセル。t="s"(文字列)ではなく数値のまま <v> を持つこと。
  assert.match(overview, /<c r="B7" s="\d+"><v>[\d.]+<\/v><\/c>/);
});

test("シナリオシートの所要(秒)は 0.0 書式の数値", () => {
  const files = readZip(buildResultsExportWorkbook(sampleModel()).toBuffer());
  const styles = files.get("xl/styles.xml");
  assert.match(styles, /formatCode="0\.0"/);
});

test("ステップシート: ステップ行は outlineLevel=1、シナリオ見出し行は outlineLevel を持たない", () => {
  const files = readZip(buildResultsExportWorkbook(sampleModel()).toBuffer());
  const steps = files.get("xl/worksheets/sheet3.xml");
  // 行2 = C.S1 の見出し行(アウトライン無し)・行3 = そのステップ(outlineLevel=1)。
  assert.match(steps, /<row r="2"[^>]*>/);
  assert.doesNotMatch(steps.match(/<row r="2"[^>]*>/)[0], /outlineLevel/);
  assert.match(steps, /<row r="3" outlineLevel="1">/);
});

test("シナリオシート・ステップシートの autoFilter とヘッダー固定(freeze pane)が張られる", () => {
  const files = readZip(buildResultsExportWorkbook(sampleModel()).toBuffer());
  const scenarios = files.get("xl/worksheets/sheet2.xml");
  assert.match(scenarios, /<autoFilter ref="A1:P3"\/>/);
  assert.match(scenarios, /<pane xSplit="3" ySplit="1" topLeftCell="D2"/);
  const steps = files.get("xl/worksheets/sheet3.xml");
  assert.match(steps, /<autoFilter ref="A1:J5"\/>/);
  assert.match(steps, /<pane xSplit="2" ySplit="1" topLeftCell="C2"/);

  const wbXml = files.get("xl/workbook.xml");
  assert.match(wbXml, /<definedNames>.*_xlnm\._FilterDatabase.*<\/definedNames>/);
});
