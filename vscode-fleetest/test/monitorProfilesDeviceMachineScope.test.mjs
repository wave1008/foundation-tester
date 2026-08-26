// monitorProfilesDeviceMachineScope.test.mjs
// MonitorProfilesController の machineDeviceUpdate 配線が (machine, name) で引き当てることの回帰テスト
// (monitorDeviceOps.test.mjs と同じ fake-deps パターン。vscode は esbuild のスタブ)。
//
// 同じ機械プロファイルに別マシンの同名デバイスが並ぶのは通常。ここが名前だけで引くと、webview で
// M1Max の行を編集したのに手元(または別マシン)のエントリが書き換わる。純粋関数側の規則は
// monitorModel.test.mjs の updateDeviceInMachineProfile 群が固定している。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

const PROFILE_SAME_NAME_ON_TWO_MACHINES = {
  ios: {
    devices: [
      { machine: "local", name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "UDID-LOCAL" },
      { machine: "M1Max", name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "UDID-M1MAX" },
    ],
  },
};

/** TestProjects/P/profiles/machines/M1.json を持つ一時ワークスペースとコントローラを作る。 */
function makeController() {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-profiles-test-"));
  const machinesDir = path.join(workspaceRoot, "TestProjects", "P", "profiles", "machines");
  fs.mkdirSync(machinesDir, { recursive: true });
  const machinePath = path.join(machinesDir, "M1.json");
  fs.writeFileSync(machinePath, `${JSON.stringify(PROFILE_SAME_NAME_ON_TWO_MACHINES, null, 2)}\n`, "utf8");
  const posts = [];
  // **コンストラクタは通さない** —— FileSystemWatcher を3つ作るが、テストの vscode スタブに
  // workspace は無い(esbuild.mjs の vscodeStubPlugin)。この経路は watcher に依存しないので
  // prototype から起こして deps だけ差す。
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "fleetest", project: "P", profile: "" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
    notifyMachineProfilesChanged: () => {},
  };
  const readDevices = () => JSON.parse(fs.readFileSync(machinePath, "utf8")).ios.devices;
  return { controller, posts, readDevices };
}

function updateMessage(deviceMachine, fields) {
  return {
    type: "machineDeviceUpdate",
    machine: "M1",
    platform: "ios",
    originalName: "シミュ1",
    ...(deviceMachine === undefined ? {} : { deviceMachine }),
    fields: { name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "", port: "", avd: "", serial: "", ...fields },
  };
}

test("machineDeviceUpdate: deviceMachine 付きは、その機械のエントリだけを書き換える", () => {
  const { controller, posts, readDevices } = makeController();
  controller.handleMachineDeviceUpdate(updateMessage("M1Max", { name: "シミュ1-改", udid: "UDID-M1MAX" }));

  assert.equal(posts.find((m) => m.type === "machineDeviceUpdateResult").ok, true);
  const devices = readDevices();
  assert.equal(devices[0].name, "シミュ1", "手元のエントリが巻き添えで書き換わっている");
  assert.equal(devices[0].udid, "UDID-LOCAL");
  assert.equal(devices[1].name, "シミュ1-改");
  assert.equal(devices[1].udid, "UDID-M1MAX");
});

test("machineDeviceUpdate: deviceMachine 省略は手元のエントリを書き換える", () => {
  const { controller, readDevices } = makeController();
  controller.handleMachineDeviceUpdate(updateMessage(undefined, { name: "シミュ1-改", udid: "UDID-LOCAL" }));

  const devices = readDevices();
  assert.equal(devices[0].name, "シミュ1-改");
  assert.equal(devices[0].udid, "UDID-LOCAL");
  assert.equal(devices[1].name, "シミュ1", "別マシンのエントリが巻き添えで書き換わっている");
});

// ---- 実体を消したあとの登録外し(unregisterDeletedDevice) ----
// **引数の machine(その台が居る機械)とマシンプロファイル名を取り違えない**。
// 2026-08-26 の改名で、走査ループの変数が引数を隠して**プロファイル名で引き当てて**おり、
// 登録が1件も外れなかった(実行プロファイル側だけ外れて台帳が食い違う)。
test("unregisterDeletedDevice: その機械の登録だけを外す(マシンプロファイル名と取り違えない)", () => {
  const { controller, readDevices } = makeController();
  const updated = controller.unregisterDeletedDevice("シミュ1", "M1Max");

  assert.deepEqual(updated.machines, ["M1"], "書き換えたマシンプロファイル名を返す");
  assert.deepEqual(
    readDevices().map((d) => `${d.machine}\t${d.name}`),
    ["local\tシミュ1"],
    "M1Max の登録だけが消え、手元の同名は残る",
  );
});

test("unregisterDeletedDevice: machine 省略は手元の登録を外す", () => {
  const { controller, readDevices } = makeController();
  const updated = controller.unregisterDeletedDevice("シミュ1", undefined);

  assert.deepEqual(updated.machines, ["M1"]);
  assert.deepEqual(readDevices().map((d) => d.machine), ["M1Max"], "手元のぶんだけ消える");
});
