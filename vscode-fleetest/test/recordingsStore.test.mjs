// recordingsStore.test.mjs
// listRecordingSessions/loadRecordingSessionDetail(src/recordingsStore.ts、vscode 非依存)の
// 回帰テスト。実ファイルシステム(mkdtempSync)上で検証する(scenarioReports.test.mjs と同じパターン)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { listRecordingSessions, loadRecordingSessionDetail, resolveSessionRunIDs } from "../src/recordingsStore";

function makeWorkspace() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-recordingsstore-test-"));
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
  return path.join(root, "TestProjects", project, "results", "runs", month, runID);
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

// 全滅run(切り出しを試みたが1本も残らなかった)の契約。recordings:[] でも clipsAttempted>0 なら
// index.json が書かれる(isRecordingIndex は recordings の中身を問わないので TS 側は空配列を素通しする)。
const EMPTY_INDEX_WITH_ATTEMPT_STATS = {
  schemaVersion: 2,
  recordings: [],
  clipsAttempted: 24,
  clipsFailed: 18,
  encoderFallback: true,
};

test("listRecordingSessions: recordings が空でもclipsAttempted>0のindex.jsonは一覧に出る(全滅run)", async () => {
  const root = makeWorkspace();
  try {
    writeJson(
      path.join(runDir(root, "SampleApp", "20260723-000000"), "recordings", "index.json"),
      EMPTY_INDEX_WITH_ATTEMPT_STATS,
    );
    const sessions = await listRecordingSessions(root);
    assert.deepEqual(
      sessions.map((s) => s.runID),
      ["20260723-000000"],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: clipsAttempted/clipsFailed/encoderFallback をsummaryへ載せる", async () => {
  const root = makeWorkspace();
  try {
    writeJson(
      path.join(runDir(root, "SampleApp", "20260723-000000"), "recordings", "index.json"),
      EMPTY_INDEX_WITH_ATTEMPT_STATS,
    );
    const sessions = await listRecordingSessions(root);
    assert.equal(sessions[0].clipsAttempted, 24);
    assert.equal(sessions[0].clipsFailed, 18);
    assert.equal(sessions[0].encoderFallback, true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: 新フィールドが無い(古い)index.jsonでもclipsAttempted/clipsFailedはnull・encoderFallbackはfalse", async () => {
  const root = makeWorkspace();
  try {
    writeJson(path.join(runDir(root, "SampleApp", "20260723-000000"), "recordings", "index.json"), SAMPLE_INDEX);
    const sessions = await listRecordingSessions(root);
    assert.equal(sessions[0].clipsAttempted, null);
    assert.equal(sessions[0].clipsFailed, null);
    assert.equal(sessions[0].encoderFallback, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: 新フィールドの型が不正でも壊れず「無い」として扱う", async () => {
  const root = makeWorkspace();
  try {
    writeJson(path.join(runDir(root, "SampleApp", "20260723-000000"), "recordings", "index.json"), {
      schemaVersion: 2,
      recordings: [],
      clipsAttempted: "24", // 文字列(不正型)
      clipsFailed: null,
      encoderFallback: "true", // 文字列(不正型)
    });
    const sessions = await listRecordingSessions(root);
    assert.equal(sessions.length, 1);
    assert.equal(sessions[0].clipsAttempted, null);
    assert.equal(sessions[0].clipsFailed, null);
    assert.equal(sessions[0].encoderFallback, false);
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

test("listRecordingSessions: workspaceRoot に TestProjects/ が無ければ空配列", async () => {
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

test("listRecordingSessions: run.json の machine と index.json の台を要約に載せる", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), {
      schemaVersion: 2,
      recordings: [
        SAMPLE_INDEX.recordings[0],
        { ...SAMPLE_INDEX.recordings[0], scenarioID: "クラス名.S0020" }, // 同じ台 → 畳まれる
        {
          scenarioID: "クラス名.S0030",
          worker: "android:Pixel 9(Android 15)-01",
          platform: "android",
          file: "recordings/クラス名-S0030.mp4",
          segments: [{ startedAt: "2026-07-23T12:40:00.000Z", durationMs: 1000 }],
        },
      ],
    });
    writeJson(path.join(dir, "run.json"), { startedAt: "2026-07-23T00:00:00Z", machine: "M1Max", passed: 3, failed: 0 });

    const [session] = await listRecordingSessions(root);
    assert.equal(session.machine, "M1Max");
    assert.deepEqual(session.devices, [
      { platform: "ios", device: "iPhone 16", machine: "M1Max" },
      { platform: "android", device: "Pixel 9(Android 15)-01", machine: "M1Max" },
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: run.json が無くても台は出る(machine だけ null)", async () => {
  const root = makeWorkspace();
  try {
    const dir = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(dir, "recordings", "index.json"), SAMPLE_INDEX);

    const [session] = await listRecordingSessions(root);
    assert.equal(session.machine, null);
    assert.deepEqual(session.devices, [{ platform: "ios", device: "iPhone 16", machine: null }]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("loadRecordingSessionDetail: machine を run.json から読む(欠落は null)", async () => {
  const root = makeWorkspace();
  try {
    const withMachine = runDir(root, "SampleApp", "20260723-000000");
    writeJson(path.join(withMachine, "recordings", "index.json"), SAMPLE_INDEX);
    writeJson(path.join(withMachine, "run.json"), { startedAt: "2026-07-23T00:00:00Z", machine: "LDIPC96" });
    const detail = await loadRecordingSessionDetail(root, "SampleApp", "20260723-000000");
    assert.equal(detail.machine, "LDIPC96");

    const noMeta = runDir(root, "SampleApp", "20260722-000000");
    writeJson(path.join(noMeta, "recordings", "index.json"), SAMPLE_INDEX);
    const detail2 = await loadRecordingSessionDetail(root, "SampleApp", "20260722-000000");
    assert.equal(detail2.machine, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ---- 機械ごとに分かれた run を束ねる(runGroup。docs/results-json.md) ----
// デバイスが複数の機械にまたがるプロファイルは機械ごとに別 run になる。束ねないと録画セッションが
// Mac ごとに並ぶ(利用者報告)。**鍵を持たない run は束ねない**(推測で混ぜない)。

/** 1機械ぶんの run を書く。worker は "<platform>:<台名>"。 */
function writeMemberRun(root, project, runID, { machine, runGroup, device, scenarioID, passed, failed }) {
  const dir = runDir(root, project, runID);
  writeJson(path.join(dir, "recordings", "index.json"), {
    schemaVersion: 2,
    recordings: [
      {
        scenarioID,
        worker: `android:${device}`,
        platform: "android",
        file: `recordings/${scenarioID}.mp4`,
        segments: [{ startedAt: "2026-08-26T01:00:00.000Z", durationMs: 1000 }],
      },
    ],
  });
  writeJson(path.join(dir, "run.json"), {
    startedAt: `2026-08-26T01:0${runID.slice(-1)}:00Z`,
    machine, passed, failed,
    ...(runGroup === null ? {} : { runGroup }),
  });
}

test("listRecordingSessions: runGroup が同じ run は1セッションに束ねる", async () => {
  const root = makeWorkspace();
  try {
    writeMemberRun(root, "SampleApp", "20260826-010000Z-LDIPC96-aaa1", {
      machine: "LDIPC96", runGroup: "G1", device: "Pixel 9-01", scenarioID: "A.S0010", passed: 2, failed: 0,
    });
    writeMemberRun(root, "SampleApp", "20260826-010012Z-M1Max-bbb2", {
      machine: "M1Max", runGroup: "G1", device: "Pixel 10-01", scenarioID: "A.S0020", passed: 1, failed: 1,
    });

    const sessions = await listRecordingSessions(root);
    assert.equal(sessions.length, 1, "2つの run が1セッションになる");
    const [session] = sessions;
    assert.deepEqual(session.runIDs, ["20260826-010000Z-LDIPC96-aaa1", "20260826-010012Z-M1Max-bbb2"]);
    assert.deepEqual(session.machines, ["M1Max", "LDIPC96"], "全マシンが出る(新しい run から先に見る)");
    assert.deepEqual(session.devices.map((d) => `${d.machine}/${d.device}`),
                     ["M1Max/Pixel 10-01", "LDIPC96/Pixel 9-01"]);
    assert.equal(session.passed, 3, "件数は合計");
    assert.equal(session.failed, 1);
    assert.equal(session.startedAt, "2026-08-26T01:01:00Z", "開始は最も早い run のもの");
    assert.equal(session.runID, "20260826-010000Z-LDIPC96-aaa1", "代表は最も古い run");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: runGroup の無い run は束ねない(推測で混ぜない)", async () => {
  const root = makeWorkspace();
  try {
    // 同じプロジェクト・ほぼ同時刻でも、鍵が無ければ別セッションのまま
    writeMemberRun(root, "SampleApp", "20260826-010000Z-LDIPC96-aaa1", {
      machine: "LDIPC96", runGroup: null, device: "Pixel 9-01", scenarioID: "A.S0010", passed: 1, failed: 0,
    });
    writeMemberRun(root, "SampleApp", "20260826-010012Z-M1Max-bbb2", {
      machine: "M1Max", runGroup: null, device: "Pixel 10-01", scenarioID: "A.S0020", passed: 1, failed: 0,
    });

    assert.equal((await listRecordingSessions(root)).length, 2);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("listRecordingSessions: 鍵が違えば束ねない(別プロジェクトの同じ鍵も混ぜない)", async () => {
  const root = makeWorkspace();
  try {
    writeMemberRun(root, "SampleApp", "20260826-010000Z-LDIPC96-aaa1", {
      machine: "LDIPC96", runGroup: "G1", device: "Pixel 9-01", scenarioID: "A.S0010", passed: 1, failed: 0,
    });
    writeMemberRun(root, "SampleApp", "20260826-010012Z-M1Max-bbb2", {
      machine: "M1Max", runGroup: "G2", device: "Pixel 10-01", scenarioID: "A.S0020", passed: 1, failed: 0,
    });
    writeMemberRun(root, "OtherApp", "20260826-010013Z-M1Ultra-ccc3", {
      machine: "M1Ultra", runGroup: "G1", device: "Pixel 3a", scenarioID: "A.S0030", passed: 1, failed: 0,
    });

    assert.equal((await listRecordingSessions(root)).length, 3);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("resolveSessionRunIDs: 鍵を共有する run を全部返す(鍵が無ければ自分だけ)", async () => {
  const root = makeWorkspace();
  try {
    writeMemberRun(root, "SampleApp", "20260826-010000Z-LDIPC96-aaa1", {
      machine: "LDIPC96", runGroup: "G1", device: "Pixel 9-01", scenarioID: "A.S0010", passed: 1, failed: 0,
    });
    writeMemberRun(root, "SampleApp", "20260826-010012Z-M1Max-bbb2", {
      machine: "M1Max", runGroup: "G1", device: "Pixel 10-01", scenarioID: "A.S0020", passed: 1, failed: 0,
    });
    writeMemberRun(root, "SampleApp", "20260826-010013Z-M1Ultra-ccc3", {
      machine: "M1Ultra", runGroup: null, device: "Pixel 3a", scenarioID: "A.S0030", passed: 1, failed: 0,
    });

    assert.deepEqual(
      await resolveSessionRunIDs(root, "SampleApp", "20260826-010012Z-M1Max-bbb2"),
      ["20260826-010000Z-LDIPC96-aaa1", "20260826-010012Z-M1Max-bbb2"],
      "どのメンバーから開いても束の全員が返る",
    );
    assert.deepEqual(
      await resolveSessionRunIDs(root, "SampleApp", "20260826-010013Z-M1Ultra-ccc3"),
      ["20260826-010013Z-M1Ultra-ccc3"],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
