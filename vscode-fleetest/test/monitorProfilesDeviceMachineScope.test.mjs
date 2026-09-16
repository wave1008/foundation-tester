// monitorProfilesDeviceMachineScope.test.mjs
// MonitorProfilesController の unregisterDeletedDevice が (platform, machine, name) で
// 引き当てることの回帰テスト(monitorDeviceOps.test.mjs と同じ fake-deps パターン。vscode は
// esbuild のスタブ)。
//
// 同じ機械に別マシンの同名デバイスが並ぶのは通常(プロジェクトのデバイスカタログ = 全実行
// プロファイルの devices[] の和集合)。ここが名前だけで引くと、実体を削除したのに手元
// (または別マシン)のエントリが登録から外れる。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

const RUN_PROFILE_SAME_NAME_ON_TWO_MACHINES = {
  app: "sampleapp",
  devices: [
    { platform: "ios", machine: "local", name: "シミュ1", model: "iPhone 16", osVersion: "iOS 18.0", udid: "UDID-LOCAL" },
    { platform: "ios", machine: "M1Max", name: "シミュ1", model: "iPhone 16", osVersion: "iOS 18.0", udid: "UDID-M1MAX" },
  ],
};

/** TestProjects/P/profiles/runs/ios.json を持つ一時ワークスペースとコントローラを作る。 */
function makeController() {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-profiles-test-"));
  const runsDir = path.join(workspaceRoot, "TestProjects", "P", "profiles", "runs");
  fs.mkdirSync(runsDir, { recursive: true });
  const runPath = path.join(runsDir, "ios.json");
  fs.writeFileSync(runPath, `${JSON.stringify(RUN_PROFILE_SAME_NAME_ON_TWO_MACHINES, null, 2)}\n`, "utf8");
  const posts = [];
  // **コンストラクタは通さない** —— FileSystemWatcher を作るが、テストの vscode スタブに
  // workspace は無い(esbuild.mjs の vscodeStubPlugin)。この経路は watcher に依存しないので
  // prototype から起こして deps だけ差す。
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "fleetest", project: "P", profile: "" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
    notifyProjectDeviceCatalogChanged: () => {},
  };
  const readDevices = () => JSON.parse(fs.readFileSync(runPath, "utf8")).devices;
  return { controller, posts, readDevices };
}

// ---- 実体を消したあとの登録外し(unregisterDeletedDevice) ----
// **引数の machine(その台が居る機械)と実行プロファイル名を取り違えない**。
test("unregisterDeletedDevice: その機械の登録だけを外す(実行プロファイル名と取り違えない)", () => {
  const { controller, readDevices } = makeController();
  const updated = controller.unregisterDeletedDevice("ios", "シミュ1", "M1Max");

  assert.deepEqual(updated.runs, ["ios"], "書き換えた実行プロファイル名を返す");
  assert.deepEqual(
    readDevices().map((d) => `${d.machine}\t${d.name}`),
    ["local\tシミュ1"],
    "M1Max の登録だけが消え、手元の同名は残る",
  );
});

test("unregisterDeletedDevice: machine 省略は手元の登録を外す", () => {
  const { controller, readDevices } = makeController();
  const updated = controller.unregisterDeletedDevice("ios", "シミュ1", undefined);

  assert.deepEqual(updated.runs, ["ios"]);
  assert.deepEqual(readDevices().map((d) => d.machine), ["M1Max"], "手元のぶんだけ消える");
});
