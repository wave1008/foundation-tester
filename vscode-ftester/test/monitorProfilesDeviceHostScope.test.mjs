// monitorProfilesDeviceHostScope.test.mjs
// MonitorProfilesController の machineDeviceUpdate 配線が (host, name) で引き当てることの回帰テスト
// (monitorDeviceOps.test.mjs と同じ fake-deps パターン。vscode は esbuild のスタブ)。
//
// 同じ機械プロファイルに別ホストの同名デバイスが並ぶのは通常。ここが名前だけで引くと、webview で
// M1Max の行を編集したのに手元(または別ホスト)のエントリが書き換わる。純粋関数側の規則は
// monitorModel.test.mjs の updateDeviceInMachineProfile 群が固定している。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

const PROFILE_SAME_NAME_ON_TWO_HOSTS = {
  ios: {
    devices: [
      { host: "local", name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "UDID-LOCAL" },
      { host: "M1Max", name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "UDID-M1MAX" },
    ],
  },
};

/** TestProjects/P/profiles/machines/M1.json を持つ一時ワークスペースとコントローラを作る。 */
function makeController() {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-profiles-test-"));
  const machinesDir = path.join(workspaceRoot, "TestProjects", "P", "profiles", "machines");
  fs.mkdirSync(machinesDir, { recursive: true });
  const machinePath = path.join(machinesDir, "M1.json");
  fs.writeFileSync(machinePath, `${JSON.stringify(PROFILE_SAME_NAME_ON_TWO_HOSTS, null, 2)}\n`, "utf8");
  const posts = [];
  // **コンストラクタは通さない** —— FileSystemWatcher を3つ作るが、テストの vscode スタブに
  // workspace は無い(esbuild.mjs の vscodeStubPlugin)。この経路は watcher に依存しないので
  // prototype から起こして deps だけ差す。
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "ftester", project: "P", profile: "" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
    notifyMachineProfilesChanged: () => {},
  };
  const readDevices = () => JSON.parse(fs.readFileSync(machinePath, "utf8")).ios.devices;
  return { controller, posts, readDevices };
}

function updateMessage(host, fields) {
  return {
    type: "machineDeviceUpdate",
    machine: "M1",
    platform: "ios",
    originalName: "シミュ1",
    ...(host === undefined ? {} : { host }),
    fields: { name: "シミュ1", simulator: "iPhone 16", os: "18.0", udid: "", port: "", avd: "", serial: "", ...fields },
  };
}

test("machineDeviceUpdate: host 付きは、その機械のエントリだけを書き換える", () => {
  const { controller, posts, readDevices } = makeController();
  controller.handleMachineDeviceUpdate(updateMessage("M1Max", { name: "シミュ1-改", udid: "UDID-M1MAX" }));

  assert.equal(posts.find((m) => m.type === "machineDeviceUpdateResult").ok, true);
  const devices = readDevices();
  assert.equal(devices[0].name, "シミュ1", "手元のエントリが巻き添えで書き換わっている");
  assert.equal(devices[0].udid, "UDID-LOCAL");
  assert.equal(devices[1].name, "シミュ1-改");
  assert.equal(devices[1].udid, "UDID-M1MAX");
});

test("machineDeviceUpdate: host 省略は手元のエントリを書き換える", () => {
  const { controller, readDevices } = makeController();
  controller.handleMachineDeviceUpdate(updateMessage(undefined, { name: "シミュ1-改", udid: "UDID-LOCAL" }));

  const devices = readDevices();
  assert.equal(devices[0].name, "シミュ1-改");
  assert.equal(devices[0].udid, "UDID-LOCAL");
  assert.equal(devices[1].name, "シミュ1", "別ホストのエントリが巻き添えで書き換わっている");
});
