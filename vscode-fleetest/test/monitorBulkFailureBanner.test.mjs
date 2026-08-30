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
import { isDevicesUpEvent } from "../src/monitorDeviceLifecycle";
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

// リモート機1台ぶんが丸ごと失敗しても親の finished は ok:true で来る(RemoteDeviceFanout が
// 子の finished を machineFailed に移し替える)。これをバナーに出さないとその機械の失敗が
// OUTPUT にしか残らず無音になる
test("リモート機の一括起動が丸ごと失敗したらバナーに出す(親の finished は ok:true)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ft-bulkfail-remote-"));
  const binaryPath = path.join(dir, "fleetest");
  // **printf '%s' を使う** —— sh の echo は引数中の \n を展開し、JSON が複数行に割れる
  fs.writeFileSync(binaryPath, `#!/bin/sh
printf '%s\\n' '{"kind":"machineFailed","machine":"M1Ultra","error":"no simulator with that UDID\\nsecond line"}'
printf '%s\\n' '{"kind":"finished","ok":true,"error":null}'
exit 0
`);
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
  assert.match(banner.message, /M1Ultra/, "どの機械かを言う");
  assert.match(banner.message, /no simulator with that UDID/);
  assert.doesNotMatch(banner.message, /second line/, "外から来た生のエラーは1行目だけ");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("isDevicesUpEvent: machineFailed は machine と error が揃ったときだけ通す", () => {
  assert.equal(isDevicesUpEvent({ kind: "machineFailed", machine: "M1Max", error: "x" }), true);
  assert.equal(isDevicesUpEvent({ kind: "machineFailed", machine: "", error: "x" }), false);
  assert.equal(isDevicesUpEvent({ kind: "machineFailed", machine: "M1Max" }), false);
});

