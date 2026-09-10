// monitorRecordingsReveal.test.mjs
// run 完了時の自動表示(MonitorRecordingsController.revealRun)。録画を読めた run だけを reveal 付きで
// 送り、読めない run(録画しない実行プロファイル等)では何も送らない —— ok:false を送ると webview は
// 一覧ビューへ戻るので、録画タブで別のセッションを見ている利用者の画面を壊す。
// fake-deps パターンは monitorProfilesProjectList.test.mjs と同じ。

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
      segments: [{ startedAt: "2026-09-11T01:00:00.000Z", durationMs: 60000 }],
    },
  ],
};

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value));
}

function runDir(root, project, runID) {
  return path.join(root, "TestProjects", project, "results", "runs", `${runID.slice(0, 4)}-${runID.slice(4, 6)}`, runID);
}

function makeController(t) {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-recordings-reveal-test-"));
  t.after(() => fs.rmSync(workspaceRoot, { recursive: true, force: true }));
  const posts = [];
  const controller = new MonitorRecordingsController({
    workspaceRoot,
    post: (message) => posts.push(message),
    videoWebviewUri: (filePath) => `https://localhost${filePath}`,
  });
  return { workspaceRoot, controller, posts };
}

test("revealRun: 録画のある run は reveal 付きで再生データを送る", async (t) => {
  const { workspaceRoot, controller, posts } = makeController(t);
  const dir = runDir(workspaceRoot, "SampleApp", "20260911-010000");
  writeJson(path.join(dir, "recordings", "index.json"), INDEX);
  writeJson(path.join(dir, "run.json"), { startedAt: "2026-09-11T01:00:00Z", passed: 1, failed: 0 });

  await controller.revealRun("SampleApp", "20260911-010000");

  assert.equal(posts.length, 1);
  const message = posts[0];
  assert.equal(message.type, "recordingsSession");
  assert.equal(message.reveal, true);
  assert.equal(message.ok, true);
  assert.equal(message.project, "SampleApp");
  assert.equal(message.runID, "20260911-010000");
  assert.deepEqual(message.videos.map((v) => v.scenarioID), ["クラス名.S0010"]);
});

test("revealRun: 録画の無い run(index.json 無し)では何も送らない", async (t) => {
  const { workspaceRoot, controller, posts } = makeController(t);
  writeJson(path.join(runDir(workspaceRoot, "SampleApp", "20260911-020000"), "run.json"), { passed: 1, failed: 0 });

  await controller.revealRun("SampleApp", "20260911-020000");

  assert.deepEqual(posts, []);
});

test("openSession: 利用者が開いた応答には reveal を付けない(見つからなければ従来どおり ok:false)", async (t) => {
  const { workspaceRoot, controller, posts } = makeController(t);
  writeJson(path.join(runDir(workspaceRoot, "SampleApp", "20260911-010000"), "recordings", "index.json"), INDEX);

  await controller.openSession("SampleApp", "20260911-010000");
  await controller.openSession("SampleApp", "20260911-099999");

  assert.equal(posts.length, 2);
  assert.equal(posts[0].ok, true);
  assert.equal(posts[0].reveal, undefined);
  assert.equal(posts[1].ok, false);
  assert.equal(posts[1].reveal, undefined);
});
