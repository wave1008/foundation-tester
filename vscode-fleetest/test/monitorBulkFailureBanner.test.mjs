// 一括起動/終了(bulk)の失敗を**画面に出す**ことの回帰テスト。
//
// 実害(2026-08-29): 実行プロファイル未選択のとき `api devices-up` が台帳を決められず即死して
// いたが、拡張はそれを OUTPUT にしか書いていなかった —— 利用者から見ると
// 「デバイスを全て起動を押しても何も始まらない」。CLI 側は畳んで通るよう直したが、
// **失敗が無音になる経路自体**をここで塞ぐ。
import assert from "node:assert/strict";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
import { test } from "node:test";
import { MonitorDeviceOps } from "../src/monitorDeviceOps";
test("一括起動が即失敗したらバナーに出す(ログだけにしない)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ft-bulkfail-"));
  const binaryPath = path.join(dir, "fleetest");
  fs.writeFileSync(binaryPath, `#!/bin/sh\necho '{"kind":"finished","ok":false,"error":"cannot tell which machine profile to use"}'\nexit 1\n`);
  fs.chmodSync(binaryPath, 0o755);
  const posts = [];
  const ops = new MonitorDeviceOps({ workspaceRoot: "/tmp",
    getConfig: () => ({ binaryPath, project: "P", profile: "" }),
    outputChannel: { appendLine() {} }, post: (m) => posts.push(m), writeMonitorControl: () => {},
    notifyMachineProfilesChanged: () => {}, stopDeviceStreams: () => {}, stopAllStreams: () => {} });
  ops.bulkUpWithRestarts([]);
  const t0 = Date.now();
  while (ops.isQueueBusy()) { if (Date.now() - t0 > 5000) throw new Error("timeout"); await new Promise((r) => setTimeout(r, 10)); }
  const banner = posts.find((m) => m.type === "deviceError");
  assert.ok(banner, "バナーが出ていない: " + JSON.stringify(posts.map((m) => m.type)));
  assert.match(banner.message, /machine profile/);
  fs.rmSync(dir, { recursive: true, force: true });
});
