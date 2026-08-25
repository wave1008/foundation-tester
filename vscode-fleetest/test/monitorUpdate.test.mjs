// 設定タブ「更新」セクションのホスト側検証(monitorUpdateController.ts)。
// update-check.sh を差し替えたクローンもどきに対して実際に spawn し、webview へ送るメッセージ列を見る
// (判定そのものはスクリプト側の責務。ここは「結果をどう state に写すか」だけ)。
//
// vscode API は esbuild の vscodeStubPlugin が Proxy で差し替える。**確認モーダルを通る
// runUpdate は呼ばない**(Proxy の showWarningMessage を await すると解決しない)。

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { MonitorUpdateController } from "../src/monitorUpdateController";

/** Scripts/update-check.sh が固定の kv を返すクローンもどきを作る。 */
function fakeClone(output) {
  const root = mkdtempSync(path.join(tmpdir(), "fleetest-mon-update-"));
  mkdirSync(path.join(root, "Sources", "FTScenarioRunner"), { recursive: true });
  mkdirSync(path.join(root, "Scripts"), { recursive: true });
  const script = path.join(root, "Scripts", "update-check.sh");
  writeFileSync(script, `#!/usr/bin/env bash\ncat <<'EOF'\n${output}\nEOF\n`);
  chmodSync(script, 0o755);
  return root;
}

function collector() {
  const posted = [];
  return {
    posted,
    deps: {
      workspaceRoot: "",
      outputChannel: { appendLine() {} },
      post: (message) => posted.push(message),
    },
  };
}

async function checkIn(root, output) {
  const { posted, deps } = collector();
  const controller = new MonitorUpdateController({ ...deps, workspaceRoot: root ?? fakeClone(output) });
  await controller.check();
  return posted.filter((m) => m.type === "updateStatus");
}

test("check: 判定前に checking を出し、verdict をそのまま state にする", async () => {
  const statuses = await checkIn(undefined, "verdict=up-to-date\nlocal_head=abcdef1234");
  assert.deepEqual(statuses.map((s) => s.state), ["checking", "up-to-date"]);
  assert.equal(statuses[1].localHead, "abcdef1234");
});

test("check: update-available は両方の sha を渡す(表示は webview 側で短縮)", async () => {
  const statuses = await checkIn(
    undefined,
    "verdict=update-available\nlocal_head=1111111111\nremote_head=2222222222",
  );
  assert.equal(statuses[1].state, "update-available");
  assert.equal(statuses[1].localHead, "1111111111");
  assert.equal(statuses[1].remoteHead, "2222222222");
});

test("check: pinned は理由をそのまま渡す(reason はスクリプト側の英語)", async () => {
  const statuses = await checkIn(undefined, "verdict=pinned\nreason=version pinned (detached HEAD)");
  assert.equal(statuses[1].state, "pinned");
  assert.equal(statuses[1].reason, "version pinned (detached HEAD)");
});

test("check: 知らない verdict と unknown はまとめて unknown に倒す", async () => {
  for (const output of ["verdict=unknown\nreason=cannot reach upstream", "verdict=weird", ""]) {
    const statuses = await checkIn(undefined, output);
    assert.equal(statuses[1].state, "unknown", `output=${JSON.stringify(output)}`);
  }
});

test("check: クローンが見つからなければ unavailable(スクリプトを起動しない)", async () => {
  const lonely = mkdtempSync(path.join(tmpdir(), "fleetest-noclone-"));
  const statuses = await checkIn(lonely, "");
  assert.deepEqual(statuses.map((s) => s.state), ["unavailable"]);
});

test("check: update-check.sh を持たない古いクローンも unavailable", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "fleetest-oldclone-"));
  mkdirSync(path.join(root, "Sources", "FTScenarioRunner"), { recursive: true });
  const statuses = await checkIn(root, "");
  assert.deepEqual(statuses.map((s) => s.state), ["unavailable"]);
});
