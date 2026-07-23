// recordingsStore.test.mjs
// listRecordingSessions/loadRecordingSessionDetail(src/recordingsStore.ts、vscode 非依存)の
// 回帰テスト。実ファイルシステム(mkdtempSync)上で検証する(scenarioReports.test.mjs と同じパターン)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { listRecordingSessions, loadRecordingSessionDetail } from "../src/recordingsStore";

function makeWorkspace() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "ftester-recordingsstore-test-"));
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value));
}

// v2契約(1エントリ=1シナリオの mp4。scenarioID 必須)。
const SAMPLE_INDEX = {
  schemaVersion: 2,
  recordings: [
    {
      scenarioID: "クラス名.S0010",
      worker: "ios:iPhone 16",
      platform: "ios",
      file: "recordings/クラス名-S0010.mp4",
      segments: [{ startedAt: "2026-07-23T12:34:56.789Z", durationMs: 180000 }],
    },
  ],
};

// v1(1ワーカー1動画。scenarioID 無し)。isRecordingIndex が弾くため一覧に出ないことの確認用。
const V1_INDEX = {
  schemaVersion: 1,
  recordings: [
    {
      worker: "ios:iPhone 16",
      platform: "ios",
      file: "recordings/ios-iPhone-16.mp4",
      segments: [{ startedAt: "2026-07-23T12:34:56.789Z", durationMs: 180000 }],
    },
  ],
};

function runDir(root, project, runID) {
  const month = `${runID.slice(0, 4)}-${runID.slice(4, 6)}`;
  return path.join(root, "Projects", project, "results", "runs", month, runID);
}

test("listRecordingSessions: recordings/index.json が無い run は含めない", async () => {
  const root = makeWorkspace();
  try {
    const withRecordings = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(withRecordings, "recordings", "index.json"), SAMPLE_INDEX);
    writeJson(path.join(withRecordings, "run.json"), { startedAt: "2026-07-23T00:00:00Z", passed: 4, failed: 1 });

    const withoutRecordings = runDir(root, "SampleApp", "20260722-000000");
    writeJson(path.join(withoutRecordings, "run.json"), { startedAt: "2026-07-22T00:00:00Z", passed: 5, failed: 0 });

    const sessions = await listRecordingSessions(root);
    assert.deepEqual(
      sessions.map((s) => s.runID),
      ["20260723-000000"],
    );
    assert.equal(sessions[0].passed, 4);
    assert.equal(sessions[0].failed, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: 複数プロジェクトを横断し runID 降順(新しい順)で返す", async () => {
  const root = makeWorkspace();
  try {
    writeJson(path.join(runDir(root, "AppA", "20260701-000000"), "recordings", "index.json"), SAMPLE_INDEX);
    writeJson(path.join(runDir(root, "AppB", "20260710-000000"), "recordings", "index.json"), SAMPLE_INDEX);
    writeJson(path.join(runDir(root, "AppA", "20260705-000000"), "recordings", "index.json"), SAMPLE_INDEX);

    const sessions = await listRecordingSessions(root);
    assert.deepEqual(
      sessions.map((s) => s.runID),
      ["20260710-000000", "20260705-000000", "20260701-000000"],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: run.json が欠けていても passed/failed は null で一覧に含める", async () => {
  const root = makeWorkspace();
  try {
    writeJson(path.join(runDir(root, "SampleApp", "20260723-000000"), "recordings", "index.json"), SAMPLE_INDEX);
    const sessions = await listRecordingSessions(root);
    assert.equal(sessions.length, 1);
    assert.equal(sessions[0].passed, null);
    assert.equal(sessions[0].failed, null);
    assert.equal(sessions[0].startedAt, "20260723-000000"); // run.json 無し: runID にフォールバック
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: 上限50件を超える場合は新しい順に50件へ切り詰める", async () => {
  const root = makeWorkspace();
  try {
    for (let i = 1; i <= 52; i++) {
      const runID = `20260701-${String(i).padStart(6, "0")}`;
      writeJson(path.join(runDir(root, "SampleApp", runID), "recordings", "index.json"), SAMPLE_INDEX);
    }
    const sessions = await listRecordingSessions(root);
    assert.equal(sessions.length, 50);
    assert.equal(sessions[0].runID, "20260701-000052");
    assert.equal(sessions[49].runID, "20260701-000003");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: schemaVersion:1(v1)の古いセッションは一覧に出さない", async () => {
  const root = makeWorkspace();
  try {
    writeJson(path.join(runDir(root, "SampleApp", "20260701-000000"), "recordings", "index.json"), V1_INDEX);
    writeJson(path.join(runDir(root, "SampleApp", "20260702-000000"), "recordings", "index.json"), SAMPLE_INDEX);
    const sessions = await listRecordingSessions(root);
    assert.deepEqual(
      sessions.map((s) => s.runID),
      ["20260702-000000"],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: workspaceRoot に Projects/ が無ければ空配列", async () => {
  const root = makeWorkspace();
  try {
    assert.deepEqual(await listRecordingSessions(root), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: index.json と scenarios/*.json を読み込む", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), SAMPLE_INDEX);
    writeJson(path.join(dir, "scenarios", "Login.json"), { scenarioID: "Login", startedAt: "2026-07-23T00:00:00Z", passed: false });
    writeJson(path.join(dir, "scenarios", "Checkout.json"), { scenarioID: "Checkout", startedAt: "2026-07-23T00:01:00Z", passed: true });

    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.ok(detail);
    assert.equal(detail.runDir, dir);
    assert.deepEqual(detail.index, SAMPLE_INDEX);
    assert.equal(detail.scenarios.length, 2);
    const scenarioIDs = detail.scenarios.map((s) => s.scenarioID).sort();
    assert.deepEqual(scenarioIDs, ["Checkout", "Login"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: scenarios/ ディレクトリが無くてもindexだけで成立する", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), SAMPLE_INDEX);
    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.ok(detail);
    assert.deepEqual(detail.scenarios, []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: recordings/index.json が無ければnull", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "run.json"), { startedAt: "2026-07-23T00:00:00Z" });
    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.equal(detail, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: 壊れたindex.json(スキーマ不一致)はnull", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), { schemaVersion: 2, recordings: [{ worker: "w" }] }); // scenarioID 欠落
    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.equal(detail, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: schemaVersion:1(v1)のindex.jsonはnull", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), V1_INDEX);
    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.equal(detail, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
