// monitorModel.test.mjs
// monitorModel.ts(isMonitorEvent/toWebviewMessage/isMonitorFromWebviewMessage)のユニットテスト。
// node:test で実行する。esbuild が "../src/monitorModel"(拡張子なし)を monitorModel.ts に
// 解決してバンドルする。
//
// 末尾に、mock-monitor.mjs を実際に spawn して NdjsonParser → monitorModel に通す
// 統合テストを1本含む(monitorPanel.ts の配線を再現する。runReducer.test.mjs の
// mock-runner.mjs 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  addDevicesToMachineProfile,
  buildRunProfileTemplate,
  bulkLifecycleOp,
  createDeviceLifecycleQueueState,
  finishDeviceLifecycleJob,
  deviceLifecycleJobNeedsMonitorPause,
  promoteDeviceLifecycleJobs,
  deviceLifecycleStatusFor,
  deviceOpMenuItem,
  devicesToShutdownOnScopeChange,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  isCreateDeviceEvent,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesRestartEvent,
  isDevicesUpEvent,
  isInstalledDevicesJson,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  machineDeviceDetail,
  monitorControlLine,
  parseAppProfileForForm,
  parseRunProfileForForm,
  removeDeviceFromMachineProfile,
  removeQueuedBulkUpJob,
  syncDevicesInMachineProfile,
  toWebviewMessage,
  updateAppProfileInObject,
  updateDeviceInMachineProfile,
  updateRunProfileInObject,
  validateNewAppProfileName,
  validateNewDeviceName,
  validateNewMachineProfileName,
  validateNewRunProfileName,
} from "../src/monitorModel";

// esbuild がこのテストを out-test/ にバンドルするため、import.meta.url はバンドル後の
// 場所を指す。npm test は常に vscode-ftester/ を cwd として実行されるので、
// process.cwd() を基準に test/fixtures/ を解決する(runReducer.test.mjs と同じ理由)。
const MOCK_MONITOR = path.resolve(process.cwd(), "test", "fixtures", "mock-monitor.mjs");
const MOCK_DEVICE_OP = path.resolve(process.cwd(), "test", "fixtures", "mock-device-op.mjs");

// ---- isMonitorEvent: 正常3種 ----

test("isMonitorEvent: monitorDevices の正常な値を true と判定する", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "接続済み" },
      { id: "android:エミュ1", name: "エミュ1", platform: "android", state: "offline", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorFrame の正常な値を true と判定する", () => {
  const value = {
    kind: "monitorFrame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorError の正常な値(device あり)を true と判定する", () => {
  const value = { kind: "monitorError", device: "ios:シミュ1", message: "接続できません" };
  assert.equal(isMonitorEvent(value), true);
});

test("isMonitorEvent: monitorError は device 省略でも true(契約上 device は省略されうる)", () => {
  const value = { kind: "monitorError", message: "マシンプロファイルが未設定です" };
  assert.equal(isMonitorEvent(value), true);
});

// ---- isMonitorEvent: 不正kind ----

test("isMonitorEvent: 未知の kind は false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorSomethingUnknown" }), false);
  assert.equal(isMonitorEvent({ kind: 123 }), false);
  assert.equal(isMonitorEvent({}), false);
  assert.equal(isMonitorEvent(null), false);
  assert.equal(isMonitorEvent("not an object"), false);
  assert.equal(isMonitorEvent(undefined), false);
});

// ---- isMonitorEvent: フィールド欠落 ----

test("isMonitorEvent: monitorDevices は devices 配列が無ければ false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorDevices" }), false);
  assert.equal(isMonitorEvent({ kind: "monitorDevices", devices: "not-an-array" }), false);
});

test("isMonitorEvent: monitorDevices は要素の state が欠落/不正なら false", () => {
  const missingState = {
    kind: "monitorDevices",
    devices: [{ id: "ios:シミュ1", name: "シミュ1", platform: "ios", detail: "" }],
  };
  assert.equal(isMonitorEvent(missingState), false);

  const invalidState = {
    kind: "monitorDevices",
    devices: [
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "unknown", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(invalidState), false);
});

test("isMonitorEvent: monitorDevices は要素の platform が ios/android 以外なら false", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "x", name: "x", platform: "windows", state: "connected", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(value), false);
});

test("isMonitorEvent: monitorDevices の recording は欠落・非boolean値を false に正規化する(inRun と同じ方針)", () => {
  const missing = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "" }],
  };
  assert.equal(isMonitorEvent(missing), true);
  assert.equal(missing.devices[0].recording, false);

  const nullValue = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", recording: null }],
  };
  assert.equal(isMonitorEvent(nullValue), true);
  assert.equal(nullValue.devices[0].recording, false);

  const invalidType = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", recording: "true" }],
  };
  assert.equal(isMonitorEvent(invalidType), true);
  assert.equal(invalidType.devices[0].recording, false);
});

test("isMonitorEvent: monitorDevices の recording は true/false をそのまま保持する", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", recording: true },
      { id: "d2", name: "d2", platform: "android", state: "connected", detail: "", recording: false },
    ],
  };
  assert.equal(isMonitorEvent(value), true);
  assert.equal(value.devices[0].recording, true);
  assert.equal(value.devices[1].recording, false);
});

test("isMonitorEvent: monitorFrame は width/height が欠落/非数値なら false", () => {
  assert.equal(
    isMonitorEvent({ kind: "monitorFrame", device: "d", jpegBase64: "A", height: 100 }),
    false,
  );
  assert.equal(
    isMonitorEvent({
      kind: "monitorFrame",
      device: "d",
      jpegBase64: "A",
      width: "480",
      height: 100,
    }),
    false,
  );
});

test("isMonitorEvent: monitorError は message が欠落/非文字列なら false", () => {
  assert.equal(isMonitorEvent({ kind: "monitorError", device: "d" }), false);
  assert.equal(isMonitorEvent({ kind: "monitorError", message: 123 }), false);
});

// ---- toWebviewMessage: 変換 ----

test("toWebviewMessage: monitorDevices → { type: 'devices', devices }", () => {
  const devices = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "接続済み" },
  ];
  assert.deepEqual(toWebviewMessage({ kind: "monitorDevices", devices }), {
    type: "devices",
    devices,
  });
});

test("toWebviewMessage: monitorFrame → { type: 'frame', ... }", () => {
  const event = {
    kind: "monitorFrame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  };
  assert.deepEqual(toWebviewMessage(event), {
    type: "frame",
    device: "ios:シミュ1",
    jpegBase64: "AAAA",
    width: 480,
    height: 1040,
  });
});

test("toWebviewMessage: monitorError → { type: 'deviceError', device, message }", () => {
  const event = { kind: "monitorError", device: "ios:シミュ2", message: "接続できません" };
  assert.deepEqual(toWebviewMessage(event), {
    type: "deviceError",
    device: "ios:シミュ2",
    message: "接続できません",
  });
});

// ---- isMonitorFromWebviewMessage ----

test("isMonitorFromWebviewMessage: ready/devicesUp/devicesDown/restartMonitor を true と判定する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "ready" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesDown" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "restartMonitor" }), true);
});

test("isMonitorFromWebviewMessage: 未知の type や不正値は false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "unknown" }), false);
  assert.equal(isMonitorFromWebviewMessage({}), false);
  assert.equal(isMonitorFromWebviewMessage(null), false);
  assert.equal(isMonitorFromWebviewMessage("devicesUp"), false);
});

test("isMonitorFromWebviewMessage: streamStall は scope=live なら device 不要、tile/未指定は device 必須", () => {
  // ライブタブ餓死自己修復(scope=live): device なしで有効
  assert.equal(isMonitorFromWebviewMessage({ type: "streamStall", scope: "live" }), true);
  // タイル(未指定=従来互換)は device 必須
  assert.equal(isMonitorFromWebviewMessage({ type: "streamStall", device: "sim-1" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "streamStall", scope: "tile", device: "sim-1" }), true);
  // device も scope=live も無ければ不正
  assert.equal(isMonitorFromWebviewMessage({ type: "streamStall" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "streamStall", device: "" }), false);
});

test("isMonitorFromWebviewMessage: deviceOp は name(string)+op(up/down)が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "up" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "down" }), true);
});

test("isMonitorFromWebviewMessage: deviceOp は name欠落/opが不正語彙なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", op: "up" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "boot" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: 1, op: "up" }), false);
});

test("isMonitorFromWebviewMessage: openLiveForDevice は id(非空文字列)があれば true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "ios:iPhone" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: 1 }), false);
});

test("isMonitorFromWebviewMessage: selectProfile は profile(string、空文字も可)があれば true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "selectProfile", profile: "profileA" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "selectProfile", profile: "" }), true);
});

test("isMonitorFromWebviewMessage: selectProfile は profile 欠落/非文字列なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "selectProfile" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "selectProfile", profile: 123 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "selectProfile", profile: null }), false);
});

// ---- isMonitorFromWebviewMessage: プロファイル管理(profileAdd/profileCopy/profileRename/profileDelete) ----

test("isMonitorFromWebviewMessage: profileAdd は常に true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "profileAdd" }), true);
});

test("isMonitorFromWebviewMessage: profileCopy/profileRename/profileDelete は profile が非空文字列なら true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "profileCopy", profile: "a" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "profileRename", profile: "a" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "profileDelete", profile: "a" }), true);
});

test("isMonitorFromWebviewMessage: profileCopy/profileRename/profileDelete は profile 空文字/欠落/非文字列なら false", () => {
  for (const type of ["profileCopy", "profileRename", "profileDelete"]) {
    assert.equal(isMonitorFromWebviewMessage({ type, profile: "" }), false);
    assert.equal(isMonitorFromWebviewMessage({ type }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, profile: 123 }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, profile: null }), false);
  }
});

// ---- isDeviceOpEvent ----

test("isDeviceOpEvent: log/finished(ok:true/false)の正常な値を true と判定する", () => {
  assert.equal(isDeviceOpEvent({ kind: "log", message: "起動しています..." }), true);
  assert.equal(isDeviceOpEvent({ kind: "finished", ok: true, error: null }), true);
  assert.equal(isDeviceOpEvent({ kind: "finished", ok: false, error: "失敗しました" }), true);
});

test("isDeviceOpEvent: 未知のkind・フィールド欠落/型不一致は false", () => {
  assert.equal(isDeviceOpEvent({ kind: "unknown" }), false);
  assert.equal(isDeviceOpEvent({ kind: "log" }), false);
  assert.equal(isDeviceOpEvent({ kind: "log", message: 123 }), false);
  assert.equal(isDeviceOpEvent({ kind: "finished", ok: "true", error: null }), false);
  assert.equal(isDeviceOpEvent({ kind: "finished", ok: false, error: 123 }), false);
  assert.equal(isDeviceOpEvent(null), false);
});

// ---- isDevicesUpEvent ----

test("isDevicesUpEvent: log/deviceStarting/deviceFinished/finished(ok:true/false)の正常な値を true と判定する", () => {
  assert.equal(isDevicesUpEvent({ kind: "log", message: "起動しています..." }), true);
  assert.equal(isDevicesUpEvent({ kind: "deviceStarting", name: "シミュ1", platform: "ios" }), true);
  assert.equal(isDevicesUpEvent({ kind: "deviceFinished", name: "シミュ1", platform: "ios" }), true);
  assert.equal(isDevicesUpEvent({ kind: "finished", ok: true, error: null }), true);
  assert.equal(isDevicesUpEvent({ kind: "finished", ok: false, error: "失敗しました" }), true);
});

test("isDevicesUpEvent: 未知のkind・フィールド欠落/型不一致は false", () => {
  assert.equal(isDevicesUpEvent({ kind: "unknown" }), false);
  assert.equal(isDevicesUpEvent({ kind: "log" }), false);
  assert.equal(isDevicesUpEvent({ kind: "log", message: 123 }), false);
  assert.equal(isDevicesUpEvent({ kind: "deviceStarting" }), false);
  assert.equal(isDevicesUpEvent({ kind: "deviceStarting", name: "シミュ1" }), false);
  assert.equal(isDevicesUpEvent({ kind: "deviceStarting", name: 123, platform: "ios" }), false);
  assert.equal(isDevicesUpEvent({ kind: "deviceFinished", name: "シミュ1", platform: 123 }), false);
  assert.equal(isDevicesUpEvent({ kind: "finished", ok: "true", error: null }), false);
  assert.equal(isDevicesUpEvent({ kind: "finished", ok: false, error: 123 }), false);
  assert.equal(isDevicesUpEvent(null), false);
});

// ---- deviceOpMenuItem ----

test("deviceOpMenuItem: busy 無し・offline は「起動」(op:up)、connected/booted は「停止」(op:down)", () => {
  assert.deepEqual(deviceOpMenuItem("offline", undefined), { label: "起動", op: "up", disabled: false });
  assert.deepEqual(deviceOpMenuItem("connected", undefined), { label: "停止", op: "down", disabled: false });
  assert.deepEqual(deviceOpMenuItem("booted", undefined), { label: "停止", op: "down", disabled: false });
});

test("deviceOpMenuItem: busy.status='running' なら state に関わらず実行中表示(disabled:true)", () => {
  assert.deepEqual(deviceOpMenuItem("offline", { op: "up", status: "running" }), {
    label: "起動中...",
    op: "up",
    disabled: true,
  });
  assert.deepEqual(deviceOpMenuItem("connected", { op: "up", status: "running" }), {
    label: "起動中...",
    op: "up",
    disabled: true,
  });
  assert.deepEqual(deviceOpMenuItem("offline", { op: "down", status: "running" }), {
    label: "停止中...",
    op: "down",
    disabled: true,
  });
  assert.deepEqual(deviceOpMenuItem("connected", { op: "down", status: "running" }), {
    label: "停止中...",
    op: "down",
    disabled: true,
  });
});

test("deviceOpMenuItem: busy.status='queued' なら op に関わらず「待機中...」(disabled:true)", () => {
  assert.deepEqual(deviceOpMenuItem("offline", { op: "up", status: "queued" }), {
    label: "待機中...",
    op: "up",
    disabled: true,
  });
  assert.deepEqual(deviceOpMenuItem("connected", { op: "down", status: "queued" }), {
    label: "待機中...",
    op: "down",
    disabled: true,
  });
});

// ---- DeviceLifecycleQueue: スケジューラの純粋ロジック(promote/finish・device 2並行) ----

function promoted(state) {
  const r = promoteDeviceLifecycleJobs(state);
  return r;
}

test("DeviceLifecycleQueue: 空のキューは busy:false・promote しても何も始まらない", () => {
  const state = createDeviceLifecycleQueueState();
  assert.equal(isDeviceLifecycleQueueBusy(state), false);
  assert.deepEqual(promoted(state).started, []);
});

test("DeviceLifecycleQueue: device ジョブは2台まで同時に running になる(右クリック起動の2台並行)", () => {
  let state = createDeviceLifecycleQueueState();
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ2", op: "up" });
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ3", op: "up" });
  const r = promoted(state);
  assert.equal(r.started.length, 2, "同時実行は2台まで");
  state = r.state;
  assert.deepEqual(deviceLifecycleStatusFor(state, "シミュ1"), { op: "up", status: "running" });
  assert.deepEqual(deviceLifecycleStatusFor(state, "シミュ2"), { op: "up", status: "running" });
  assert.deepEqual(deviceLifecycleStatusFor(state, "シミュ3"), { op: "up", status: "queued" });

  // 1台完了すると3台目が開始できる
  const fin = finishDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  const r2 = promoted(fin.state);
  assert.equal(r2.started.length, 1);
  assert.deepEqual(deviceLifecycleStatusFor(r2.state, "シミュ3"), { op: "up", status: "running" });
});

test("DeviceLifecycleQueue: 同一デバイス名のジョブは同時に実行しない(down→up ペアの逐次性)", () => {
  let state = createDeviceLifecycleQueueState();
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "down" });
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  const r = promoted(state);
  assert.equal(r.started.length, 1, "down だけ開始し、同名の up は待つ");
  const fin = finishDeviceLifecycleJob(r.state, { kind: "device", name: "シミュ1", op: "down" });
  const r2 = promoted(fin.state);
  assert.deepEqual(r2.started, [{ kind: "device", name: "シミュ1", op: "up" }]);
});

test("DeviceLifecycleQueue: bulk は単独占有(device 実行中は待ち、bulk 実行中は device が待つ)", () => {
  let state = createDeviceLifecycleQueueState();
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  state = enqueueDeviceLifecycleJob(state, { kind: "bulk", op: "up" });
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ2", op: "up" });
  let r = promoted(state);
  assert.equal(r.started.length, 1, "device 1台のみ開始(bulk は running が空くまで待つ。追い越しもしない)");
  const fin = finishDeviceLifecycleJob(r.state, { kind: "device", name: "シミュ1", op: "up" });
  r = promoted(fin.state);
  assert.deepEqual(r.started, [{ kind: "bulk", op: "up" }], "bulk は単独で開始し後続 device は待つ");
  assert.deepEqual(deviceLifecycleStatusFor(r.state, "シミュ2"), { op: "up", status: "queued" });
});

test("DeviceLifecycleQueue: 全件完了で busy:false・存在しないジョブの finish は例外", () => {
  let state = createDeviceLifecycleQueueState();
  state = enqueueDeviceLifecycleJob(state, { kind: "bulk", op: "up" });
  state = promoted(state).state;
  state = finishDeviceLifecycleJob(state, { kind: "bulk", op: "up" }).state;
  assert.equal(isDeviceLifecycleQueueBusy(state), false);
  assert.throws(() => finishDeviceLifecycleJob(state, { kind: "bulk", op: "up" }));
});

test("bulkLifecycleOp: キュー内(実行中/待機中問わず)の bulk ジョブの op を返す(無ければ null)", () => {
  let state = createDeviceLifecycleQueueState();
  assert.equal(bulkLifecycleOp(state), null);
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  assert.equal(bulkLifecycleOp(state), null);
  state = enqueueDeviceLifecycleJob(state, { kind: "bulk", op: "down" });
  assert.equal(bulkLifecycleOp(state), "down");
  state = promoteDeviceLifecycleJobs(state).state;
  state = finishDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" }).state; // device up 完了
  state = promoteDeviceLifecycleJobs(state).state;
  state = finishDeviceLifecycleJob(state, { kind: "bulk", op: "down" }).state; // bulk down 完了
  assert.equal(bulkLifecycleOp(state), null);
  state = enqueueDeviceLifecycleJob(state, { kind: "bulk", op: "up" });
  assert.equal(bulkLifecycleOp(state), "up");
});

test("hasDeviceLifecycleJobFor: 同じデバイス名のジョブがキュー内(実行中/待機中問わず)にあれば true", () => {
  let state = createDeviceLifecycleQueueState();
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ1", op: "up" });
  assert.equal(hasDeviceLifecycleJobFor(state, "シミュ1"), true);
  assert.equal(hasDeviceLifecycleJobFor(state, "シミュ2"), false);
  state = enqueueDeviceLifecycleJob(state, { kind: "device", name: "シミュ2", op: "up" });
  assert.equal(hasDeviceLifecycleJobFor(state, "シミュ2"), true);
});

// ---- deviceLifecycleJobNeedsMonitorPause / monitorControlLine(モニターの pause/resume 制御) ----

test("deviceLifecycleJobNeedsMonitorPause: bulk down / device down は true", () => {
  assert.equal(deviceLifecycleJobNeedsMonitorPause({ kind: "bulk", op: "down" }), true);
  assert.equal(
    deviceLifecycleJobNeedsMonitorPause({ kind: "device", name: "シミュ1", op: "down" }),
    true,
  );
});

test("deviceLifecycleJobNeedsMonitorPause: bulk up / device up は false(起動進行はタイルで見たいため)", () => {
  assert.equal(deviceLifecycleJobNeedsMonitorPause({ kind: "bulk", op: "up" }), false);
  assert.equal(
    deviceLifecycleJobNeedsMonitorPause({ kind: "device", name: "シミュ1", op: "up" }),
    false,
  );
});

test("monitorControlLine: pause/resume/suppressFrames を末尾改行付きの NDJSON 1行にする", () => {
  assert.equal(monitorControlLine({ cmd: "pause" }), '{"cmd":"pause"}\n');
  assert.equal(monitorControlLine({ cmd: "resume" }), '{"cmd":"resume"}\n');
  assert.equal(
    monitorControlLine({ cmd: "suppressFrames", devices: ["ios:シミュ1"] }),
    '{"cmd":"suppressFrames","devices":["ios:シミュ1"]}\n',
  );
  assert.equal(
    monitorControlLine({ cmd: "suppressFrames", devices: [] }),
    '{"cmd":"suppressFrames","devices":[]}\n',
  );
});

// ---- devicesToShutdownOnScopeChange(プロファイル切り替え時の自動シャットダウン対象算出) ----

const SIM1 = { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "" };
const SIM2 = { id: "ios:シミュ2", name: "シミュ2", platform: "ios", state: "booted", detail: "" };
const SIM3_OFFLINE = { id: "ios:シミュ3", name: "シミュ3", platform: "ios", state: "offline", detail: "" };
const EMU1 = { id: "android:エミュ1", name: "エミュ1", platform: "android", state: "connected", detail: "" };

test("devicesToShutdownOnScopeChange: newScopeNames が null(プロファイルなし)なら常に空配列", () => {
  assert.deepEqual(devicesToShutdownOnScopeChange([SIM1, SIM2, SIM3_OFFLINE], null), []);
  assert.deepEqual(devicesToShutdownOnScopeChange([], null), []);
});

test("devicesToShutdownOnScopeChange: offline のデバイスは新スコープ外でも対象にしない", () => {
  assert.deepEqual(devicesToShutdownOnScopeChange([SIM3_OFFLINE], []), []);
});

test("devicesToShutdownOnScopeChange: 稼働中で新スコープに含まれるデバイスは対象にしない(自動起動もしない方針と対)", () => {
  assert.deepEqual(devicesToShutdownOnScopeChange([SIM1, SIM2], ["シミュ1", "シミュ2"]), []);
});

test("devicesToShutdownOnScopeChange: 稼働中で新スコープに含まれないデバイスは元の順序で対象になる", () => {
  assert.deepEqual(
    devicesToShutdownOnScopeChange([SIM1, SIM2, EMU1, SIM3_OFFLINE], ["エミュ1"]),
    ["シミュ1", "シミュ2"],
  );
});

test("devicesToShutdownOnScopeChange: 複数該当時も devices の並び順のまま返す", () => {
  assert.deepEqual(devicesToShutdownOnScopeChange([EMU1, SIM1, SIM2], []), ["エミュ1", "シミュ1", "シミュ2"]);
});

// ---- validateNewRunProfileName(新規/コピー先の実行プロファイル名検証) ----

test("validateNewRunProfileName: 妥当な名前は null(問題なし)", () => {
  assert.equal(validateNewRunProfileName("ios", []), null);
  assert.equal(validateNewRunProfileName("my-profile_1", ["ios"]), null);
});

test("validateNewRunProfileName: 空文字はエラー", () => {
  assert.notEqual(validateNewRunProfileName("", []), null);
});

test("validateNewRunProfileName: 前後に空白を含む(trim済みでない)場合はエラー", () => {
  assert.notEqual(validateNewRunProfileName(" ios", []), null);
  assert.notEqual(validateNewRunProfileName("ios ", []), null);
});

test("validateNewRunProfileName: '/' や '\\\\' を含む場合はエラー", () => {
  assert.notEqual(validateNewRunProfileName("a/b", []), null);
  assert.notEqual(validateNewRunProfileName("a\\b", []), null);
});

test("validateNewRunProfileName: '.' で始まる場合はエラー", () => {
  assert.notEqual(validateNewRunProfileName(".hidden", []), null);
});

test("validateNewRunProfileName: 既存名と重複する場合はエラー", () => {
  assert.notEqual(validateNewRunProfileName("ios", ["ios", "android"]), null);
});

// ---- validateNewMachineProfileName(新規/リネーム後のマシンプロファイル名検証) ----

test("validateNewMachineProfileName: 妥当な名前は null(問題なし)", () => {
  assert.equal(validateNewMachineProfileName("M1 Max", []), null);
  assert.equal(validateNewMachineProfileName("my-machine_1", ["M1 Max"]), null);
});

test("validateNewMachineProfileName: 空文字はエラー", () => {
  assert.notEqual(validateNewMachineProfileName("", []), null);
});

test("validateNewMachineProfileName: 前後に空白を含む(trim済みでない)場合はエラー", () => {
  assert.notEqual(validateNewMachineProfileName(" M1 Max", []), null);
  assert.notEqual(validateNewMachineProfileName("M1 Max ", []), null);
});

test("validateNewMachineProfileName: '/' や '\\\\' を含む場合はエラー", () => {
  assert.notEqual(validateNewMachineProfileName("a/b", []), null);
  assert.notEqual(validateNewMachineProfileName("a\\b", []), null);
});

test("validateNewMachineProfileName: '.' で始まる場合はエラー", () => {
  assert.notEqual(validateNewMachineProfileName(".hidden", []), null);
});

test("validateNewMachineProfileName: 既存名と完全一致する場合はエラー", () => {
  assert.notEqual(validateNewMachineProfileName("M1 Max", ["M1 Max", "M2 Ultra"]), null);
});

test("validateNewMachineProfileName: 既存名と大文字小文字違いで重複する場合もエラー(macOSのFSがcase-insensitiveなため)", () => {
  assert.notEqual(validateNewMachineProfileName("m1 max", ["M1 Max"]), null);
  assert.notEqual(validateNewMachineProfileName("M1 MAX", ["m1 max"]), null);
});

// ---- validateNewAppProfileName(新規/コピー先/リネーム後のアプリプロファイル名検証) ----

test("validateNewAppProfileName: 妥当な名前は null(問題なし)", () => {
  assert.equal(validateNewAppProfileName("sampleapp", []), null);
  assert.equal(validateNewAppProfileName("my-app_1", ["sampleapp"]), null);
});

test("validateNewAppProfileName: 空文字はエラー", () => {
  assert.notEqual(validateNewAppProfileName("", []), null);
});

test("validateNewAppProfileName: 前後に空白を含む(trim済みでない)場合はエラー", () => {
  assert.notEqual(validateNewAppProfileName(" sampleapp", []), null);
  assert.notEqual(validateNewAppProfileName("sampleapp ", []), null);
});

test("validateNewAppProfileName: '/' や '\\\\' を含む場合はエラー", () => {
  assert.notEqual(validateNewAppProfileName("a/b", []), null);
  assert.notEqual(validateNewAppProfileName("a\\b", []), null);
});

test("validateNewAppProfileName: '.' で始まる場合はエラー", () => {
  assert.notEqual(validateNewAppProfileName(".hidden", []), null);
});

test("validateNewAppProfileName: 既存名と重複する場合はエラー", () => {
  assert.notEqual(validateNewAppProfileName("sampleapp", ["sampleapp", "otherapp"]), null);
});

// ---- buildRunProfileTemplate(新規実行プロファイルのテンプレートJSON生成) ----

test("buildRunProfileTemplate: apps/devices 候補ありなら先頭のappと全devicesを使う", () => {
  const json = buildRunProfileTemplate("M1 Max", ["sampleapp", "otherapp"], ["シミュ1", "エミュ1"]);
  assert.ok(json.endsWith("\n"));
  const parsed = JSON.parse(json);
  assert.deepEqual(parsed, {
    machine: "M1 Max",
    app: "sampleapp",
    devices: [{ name: "シミュ1" }, { name: "エミュ1" }],
    heal: false,
    iosInappEngine: true,
    wipeDataOnBloat: true,
    reportDir: "reports",
  });
});

test("buildRunProfileTemplate: 候補が無ければ app は空文字、devices は空文字1件のプレースホルダー", () => {
  const json = buildRunProfileTemplate("M1 Max", [], []);
  const parsed = JSON.parse(json);
  assert.deepEqual(parsed, {
    machine: "M1 Max",
    app: "",
    devices: [{ name: "" }],
    heal: false,
    iosInappEngine: true,
    wipeDataOnBloat: true,
    reportDir: "reports",
  });
});

test("buildRunProfileTemplate: machine が空文字なら machine キー自体を含めない", () => {
  const json = buildRunProfileTemplate("", ["sampleapp"], ["シミュ1"]);
  const parsed = JSON.parse(json);
  assert.equal("machine" in parsed, false);
  assert.deepEqual(parsed, {
    app: "sampleapp",
    devices: [{ name: "シミュ1" }],
    heal: false,
    iosInappEngine: true,
    wipeDataOnBloat: true,
    reportDir: "reports",
  });
});

// ---- isMonitorFromWebviewMessage: マシンプロファイル(machineProfileRefresh/deviceCatalogRequest/createDevice) ----

test("isMonitorFromWebviewMessage: machineProfileRefresh/deviceCatalogRequest/installedDevicesRequest は常に true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineProfileRefresh" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceCatalogRequest" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "installedDevicesRequest" }), true);
});

// ---- isMonitorFromWebviewMessage: マシンプロファイル自体の追加/削除/名前変更 ----

test("isMonitorFromWebviewMessage: machineProfileAdd は常に true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineProfileAdd" }), true);
});

test("isMonitorFromWebviewMessage: machineProfileCopy/Delete/Rename は machine が非空文字列なら true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineProfileCopy", machine: "M1" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineProfileDelete", machine: "M1" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineProfileRename", machine: "M1" }), true);
});

test("isMonitorFromWebviewMessage: machineProfileCopy/Delete/Rename は machine 空文字/欠落/非文字列なら false", () => {
  for (const type of ["machineProfileCopy", "machineProfileDelete", "machineProfileRename"]) {
    assert.equal(isMonitorFromWebviewMessage({ type, machine: "" }), false);
    assert.equal(isMonitorFromWebviewMessage({ type }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, machine: 123 }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, machine: null }), false);
  }
});

test("isMonitorFromWebviewMessage: createDevice は全フィールドが非空文字列(platformはios/android)+registerがbooleanなら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "createDevice",
      machine: "M1",
      platform: "ios",
      name: "シミュ1",
      model: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      os: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      register: true,
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "createDevice",
      machine: "M1",
      platform: "android",
      name: "エミュ1",
      model: "pixel_9_pro",
      os: "system-images;android-37;google_apis;arm64-v8a",
      register: false,
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: createDevice はフィールド欠落/空文字/不正platform/register非booleanなら false", () => {
  const base = {
    type: "createDevice",
    machine: "M1",
    platform: "ios",
    name: "n",
    model: "m",
    os: "o",
    register: true,
  };
  assert.equal(isMonitorFromWebviewMessage({ ...base, machine: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, name: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, model: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, os: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, platform: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, register: "true" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, register: undefined }), false);
  const { machine, ...missingMachine } = base;
  assert.equal(isMonitorFromWebviewMessage(missingMachine), false);
  const { register, ...missingRegister } = base;
  assert.equal(isMonitorFromWebviewMessage(missingRegister), false);
});

test("isMonitorFromWebviewMessage: machineDeviceRemove は machine 非空文字列・names 非空配列(各要素非空文字列)なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: ["シミュ1"] }),
    true,
  );
  // 複数選択の一括削除(要件5)。
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: ["シミュ1", "エミュ1"] }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDeviceRemove は machine 空文字/names 空配列・欠落・要素が空文字/非文字列なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "", names: ["シミュ1"] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: [] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: [""] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: ["OK", 1] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", names: ["シミュ1"] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1" }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDeviceRemove", machine: "M1", names: "シミュ1" }),
    false, // names は配列必須(文字列単体は不可)
  );
});

// ---- isMonitorFromWebviewMessage: machineDevicesSync(「+既存から選択」モーダルの OK) ----

const VALID_SYNC_ADD_IOS_ENTRY = {
  platform: "ios",
  name: "iPhone 17 Pro",
  simulator: "iPhone 17 Pro",
  os: "27.0",
  udid: "1C86FAKE-0000-0000-0000-000000000000",
};

const VALID_SYNC_ADD_ANDROID_ENTRY = {
  platform: "android",
  name: "Pixel 9(Android 16)",
  avd: "Pixel_9",
};

test("isMonitorFromWebviewMessage: machineDevicesSync は add のみ非空(remove:[])なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [VALID_SYNC_ADD_IOS_ENTRY, VALID_SYNC_ADD_ANDROID_ENTRY],
      remove: [],
    }),
    true,
  );
  // オプショナルフィールド(simulator/os/udid/avd)は省略可。
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [{ platform: "ios", name: "n" }],
      remove: [],
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は remove のみ非空(add:[])なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [],
      remove: ["シミュ1"],
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は add/remove 両方非空でも true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
      remove: ["シミュ1"],
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は machine 空文字なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
      remove: [],
    }),
    false,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は add/remove が両方空なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: [], remove: [] }),
    false,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は add が欠落/配列でなければ false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", remove: [] }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: "not-array", remove: [] }),
    false,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は remove が欠落/配列でなければ false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: [] }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: [], remove: "not-array" }),
    false,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は remove に空文字/非文字列要素を含むと false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: [], remove: [""] }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "machineDevicesSync", machine: "M1", add: [], remove: [123] }),
    false,
  );
});

test("isMonitorFromWebviewMessage: machineDevicesSync は add 要素が不正なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [{ platform: "ios", name: "" }],
      remove: [],
    }),
    false, // name 空文字
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [{ platform: "windows", name: "n" }],
      remove: [],
    }),
    false, // 不正 platform
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "machineDevicesSync",
      machine: "M1",
      add: [{ platform: "ios", name: "n", udid: 123 }],
      remove: [],
    }),
    false, // オプショナルフィールドの型不正
  );
});

// ---- isMonitorFromWebviewMessage: machineDeviceUpdate(プロファイルタブ右ペインの編集フォーム) ----

const VALID_MACHINE_DEVICE_UPDATE = {
  type: "machineDeviceUpdate",
  machine: "M1",
  platform: "ios",
  originalName: "シミュ1",
  fields: { name: "シミュ1", simulator: "iPhone 17 Pro", os: "27.0", udid: "", port: "", avd: "" },
};

test("isMonitorFromWebviewMessage: machineDeviceUpdate は machine/originalName 非空・platform ios|android・fields6項目 string なら true", () => {
  assert.equal(isMonitorFromWebviewMessage(VALID_MACHINE_DEVICE_UPDATE), true);
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_MACHINE_DEVICE_UPDATE,
      platform: "android",
      fields: { name: "エミュ1", simulator: "", os: "", udid: "", port: "", avd: "Pixel 9(Android 16)" },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDeviceUpdate は fields の空文字を許容する(createDevice と違い name 以外は空文字が正常値)", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_MACHINE_DEVICE_UPDATE,
      fields: { name: "シミュ1", simulator: "", os: "", udid: "", port: "", avd: "" },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: machineDeviceUpdate は machine/originalName 空文字・不正 platform・fields欠落/型不正なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_MACHINE_DEVICE_UPDATE, machine: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_MACHINE_DEVICE_UPDATE, originalName: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_MACHINE_DEVICE_UPDATE, platform: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_MACHINE_DEVICE_UPDATE, fields: null }), false);
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_MACHINE_DEVICE_UPDATE,
      fields: { name: "シミュ1", simulator: "", os: "", udid: "", avd: "" }, // port 欠落
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_MACHINE_DEVICE_UPDATE,
      fields: { name: "シミュ1", simulator: "", os: "", udid: "", port: 0, avd: "" }, // port が number
    }),
    false,
  );
  const { machine, ...missingMachine } = VALID_MACHINE_DEVICE_UPDATE;
  assert.equal(isMonitorFromWebviewMessage(missingMachine), false);
});

// ---- isMonitorFromWebviewMessage: 実行プロファイル設定フォーム(runProfileLoad/runProfileSave) ----

const VALID_RUN_PROFILE_SAVE = {
  type: "runProfileSave",
  profile: "run1",
  fields: {
    machine: "M1 Max",
    app: "sampleapp",
    devices: ["シミュ1", "エミュ1"],
    heal: false,
    iosInappEngine: true,
    reportDir: "reports",
    defaultTimeout: "10",
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "1",
    locale: "ja_JP",
    record: false,
  },
};

test("isMonitorFromWebviewMessage: runProfileLoad は profile が非空文字列なら true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileLoad", profile: "run1" }), true);
});

test("isMonitorFromWebviewMessage: runProfileLoad は profile 空文字/欠落/非文字列なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileLoad", profile: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileLoad" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileLoad", profile: 1 }), false);
});

test("isMonitorFromWebviewMessage: runProfileSave は profile 非空・fields10項目の型が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage(VALID_RUN_PROFILE_SAVE), true);
  // devices は空配列も(型としては)許容する — 「1件以上」の検証はクライアント側の別ロジックが担う。
  assert.equal(
    isMonitorFromWebviewMessage({ ...VALID_RUN_PROFILE_SAVE, fields: { ...VALID_RUN_PROFILE_SAVE.fields, devices: [] } }),
    true,
  );
  // machine/app/reportDir/defaultTimeout/wipeDataThresholdGB/locale は空文字も(型としては)許容する。
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: {
        machine: "",
        app: "",
        devices: [],
        heal: true,
        iosInappEngine: false,
        reportDir: "",
        defaultTimeout: "",
        wipeDataOnBloat: false,
        wipeDataThresholdGB: "",
        locale: "",
        record: true,
      },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: runProfileSave は profile 空文字・fields欠落/型不正なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_RUN_PROFILE_SAVE, profile: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_RUN_PROFILE_SAVE, fields: null }), false);
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, devices: ["シミュ1", 1] }, // 要素が非文字列
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, heal: "false" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, iosInappEngine: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, defaultTimeout: 10 }, // number(string でない)
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, wipeDataOnBloat: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, record: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, wipeDataThresholdGB: 1 }, // number(string でない)
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, locale: 1 }, // number(string でない)
    }),
    false,
  );
  const { fields, ...missingFields } = VALID_RUN_PROFILE_SAVE;
  assert.equal(isMonitorFromWebviewMessage(missingFields), false);
});

// ---- isMonitorFromWebviewMessage: アプリプロファイル管理(appProfileAdd/Copy/Rename/Delete) ----

test("isMonitorFromWebviewMessage: appProfileAdd は常に true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileAdd" }), true);
});

test("isMonitorFromWebviewMessage: appProfileCopy/appProfileRename/appProfileDelete は profile が非空文字列なら true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileCopy", profile: "a" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileRename", profile: "a" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileDelete", profile: "a" }), true);
});

test("isMonitorFromWebviewMessage: appProfileCopy/appProfileRename/appProfileDelete は profile 空文字/欠落/非文字列なら false", () => {
  for (const type of ["appProfileCopy", "appProfileRename", "appProfileDelete"]) {
    assert.equal(isMonitorFromWebviewMessage({ type, profile: "" }), false);
    assert.equal(isMonitorFromWebviewMessage({ type }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, profile: 123 }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, profile: null }), false);
  }
});

// ---- isMonitorFromWebviewMessage: アプリプロファイル設定フォーム(appProfileLoad/appProfileSave) ----
// common は表示名(appName)+自動インストール(autoInstall。"" は廃止済みで "true"/"false" の2値のみ)、
// ios/android は表示名・アプリID・パッケージパスの3項目(autoInstall は common に一本化された
// ため持たない。2026-07-11 指示)を持つ(monitorModel.ts の
// AppProfileCommonFields/AppProfilePlatformFields と同じ形)。

const APP_PROFILE_COMMON_FIELDS = {
  appName: "サンプル",
  autoInstall: "true",
};

const APP_PROFILE_PLATFORM_FIELDS = {
  appName: "サンプル",
  app: "com.example.sample",
  appPath: "path/to.app",
};

const VALID_APP_PROFILE_SAVE = {
  type: "appProfileSave",
  profile: "sampleapp",
  fields: {
    common: APP_PROFILE_COMMON_FIELDS,
    ios: APP_PROFILE_PLATFORM_FIELDS,
    android: APP_PROFILE_PLATFORM_FIELDS,
  },
};

test("isMonitorFromWebviewMessage: appProfileLoad は profile が非空文字列なら true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileLoad", profile: "sampleapp" }), true);
});

test("isMonitorFromWebviewMessage: appProfileLoad は profile 空文字/欠落/非文字列なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileLoad", profile: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileLoad" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "appProfileLoad", profile: 1 }), false);
});

test("isMonitorFromWebviewMessage: appProfileSave は profile 非空・fields(common=表示名+自動インストール、ios/android=3項目)の型が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage(VALID_APP_PROFILE_SAVE), true);
  // 各フィールドは空文字も(型としては)許容する。common の autoInstall は "true"/"false" の
  // 2値のみ("" は廃止)。
  const emptyCommon = { appName: "", autoInstall: "false" };
  const emptyPlatform = { appName: "", app: "", appPath: "" };
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { common: emptyCommon, ios: emptyPlatform, android: emptyPlatform },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: appProfileSave は profile 空文字・fields欠落/型不正なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_APP_PROFILE_SAVE, profile: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_APP_PROFILE_SAVE, fields: null }), false);
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: { appName: 1, autoInstall: "false" } }, // appName 非文字列
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: { ...APP_PROFILE_COMMON_FIELDS, autoInstall: "" } }, // "" は廃止済みで不正
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: { ...APP_PROFILE_COMMON_FIELDS, autoInstall: "maybe" } }, // 2値以外
    }),
    false,
  );
  const { android, ...missingAndroid } = VALID_APP_PROFILE_SAVE.fields;
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_APP_PROFILE_SAVE, fields: missingAndroid }), false);
  const { fields: appFields, ...missingAppFields } = VALID_APP_PROFILE_SAVE;
  assert.equal(isMonitorFromWebviewMessage(missingAppFields), false);
});

// ---- machineDeviceDetail ----

test("machineDeviceDetail: iOS は simulator と os を ' / iOS ' で連結する", () => {
  assert.equal(
    machineDeviceDetail({ name: "シミュ1", platform: "ios", simulator: "iPhone 17 Pro", os: "27.0" }),
    "iPhone 17 Pro / iOS 27.0",
  );
});

test("machineDeviceDetail: iOS は os が無ければ simulator のみ", () => {
  assert.equal(
    machineDeviceDetail({ name: "シミュ1", platform: "ios", simulator: "iPhone 17 Pro" }),
    "iPhone 17 Pro",
  );
});

test("machineDeviceDetail: iOS は simulator が無ければ udid の先頭8文字", () => {
  assert.equal(
    machineDeviceDetail({ name: "シミュ1", platform: "ios", udid: "ABCDEFGH-1234-5678" }),
    "ABCDEFGH",
  );
});

test("machineDeviceDetail: iOS は simulator も udid も無ければ 'iOS'", () => {
  assert.equal(machineDeviceDetail({ name: "シミュ1", platform: "ios" }), "iOS");
});

test("machineDeviceDetail: Android は avd があれば 'AVD: ' + avd", () => {
  assert.equal(
    machineDeviceDetail({ name: "エミュ1", platform: "android", avd: "Pixel 9(Android 16)" }),
    "AVD: Pixel 9(Android 16)",
  );
});

test("machineDeviceDetail: Android は avd が無ければ 'Android'", () => {
  assert.equal(machineDeviceDetail({ name: "エミュ1", platform: "android" }), "Android");
});

// ---- validateNewDeviceName ----

test("validateNewDeviceName: 妥当な名前は null", () => {
  assert.equal(validateNewDeviceName("シミュ2", ["シミュ1"]), null);
});

test("validateNewDeviceName: trim 後空ならエラー", () => {
  assert.notEqual(validateNewDeviceName("", []), null);
  assert.notEqual(validateNewDeviceName("   ", []), null);
});

test("validateNewDeviceName: 既存(ios/android横断)と重複するならエラー", () => {
  assert.notEqual(validateNewDeviceName("シミュ1", ["シミュ1", "エミュ1"]), null);
  assert.notEqual(validateNewDeviceName("  シミュ1  ", ["シミュ1"]), null); // trim後に比較
});

// ---- removeDeviceFromMachineProfile ----

test("removeDeviceFromMachineProfile: name一致のデバイスを取り除き removed:true を返す", () => {
  const profile = {
    ios: { devices: [{ name: "シミュ1", simulator: "iPhone 17 Pro" }, { name: "シミュ2" }] },
  };
  const result = removeDeviceFromMachineProfile(profile, "シミュ1");
  assert.equal(result.removed, true);
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ2" }]);
});

test("removeDeviceFromMachineProfile: 同名のエントリが複数あれば全て取り除く", () => {
  const profile = {
    ios: { devices: [{ name: "シミュ1", note: "a" }, { name: "シミュ2" }, { name: "シミュ1", note: "b" }] },
  };
  const result = removeDeviceFromMachineProfile(profile, "シミュ1");
  assert.equal(result.removed, true);
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ2" }]);
});

test("removeDeviceFromMachineProfile: name不一致なら removed:false で内容は変わらない", () => {
  const profile = { ios: { devices: [{ name: "シミュ1" }] } };
  const result = removeDeviceFromMachineProfile(profile, "存在しない名前");
  assert.equal(result.removed, false);
  assert.deepEqual(result.object, profile);
});

test("removeDeviceFromMachineProfile: 未知キー(トップレベル・セクション内・他デバイスのエントリ内)を保持する", () => {
  const profile = {
    someTopLevelKey: "keep-me",
    ios: {
      someSectionKey: "keep-me-too",
      devices: [
        { name: "シミュ1" },
        { name: "シミュ2", udid: "ABCDEFGH", customField: 123 },
      ],
    },
  };
  const result = removeDeviceFromMachineProfile(profile, "シミュ1");
  assert.equal(result.removed, true);
  assert.equal(result.object.someTopLevelKey, "keep-me");
  assert.equal(result.object.ios.someSectionKey, "keep-me-too");
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ2", udid: "ABCDEFGH", customField: 123 }]);
});

test("removeDeviceFromMachineProfile: ios・android 横断で name 一致を探す", () => {
  const profile = {
    ios: { devices: [{ name: "シミュ1" }] },
    android: { devices: [{ name: "エミュ1" }, { name: "対象" }] },
  };
  const result = removeDeviceFromMachineProfile(profile, "対象");
  assert.equal(result.removed, true);
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ1" }]); // 無関係なセクションは変化しない
  assert.deepEqual(result.object.android.devices, [{ name: "エミュ1" }]);
});

test("removeDeviceFromMachineProfile: セクション欠落・devices非配列はそのまま(false)", () => {
  const profileNoSections = { note: "no ios/android here" };
  const result1 = removeDeviceFromMachineProfile(profileNoSections, "何か");
  assert.equal(result1.removed, false);
  assert.deepEqual(result1.object, profileNoSections);

  const profileBadDevices = { ios: { devices: "not-an-array" } };
  const result2 = removeDeviceFromMachineProfile(profileBadDevices, "何か");
  assert.equal(result2.removed, false);
  assert.deepEqual(result2.object, profileBadDevices);
});

test("removeDeviceFromMachineProfile: トップレベルがオブジェクトでなければ null", () => {
  assert.equal(removeDeviceFromMachineProfile(null, "x"), null);
  assert.equal(removeDeviceFromMachineProfile("not-an-object", "x"), null);
  assert.equal(removeDeviceFromMachineProfile(42, "x"), null);
  assert.equal(removeDeviceFromMachineProfile(["ios", "android"], "x"), null);
});

// ---- updateDeviceInMachineProfile ----

function iosFields(overrides) {
  return { name: "シミュ1", simulator: "", os: "", udid: "", port: "", avd: "", ...overrides };
}

test("updateDeviceInMachineProfile: 基本更新(simulator/os変更)", () => {
  const profile = {
    ios: { devices: [{ name: "シミュ1", simulator: "iPhone 16", os: "26.0" }] },
  };
  const result = updateDeviceInMachineProfile(
    profile,
    "ios",
    "シミュ1",
    iosFields({ simulator: "iPhone 17 Pro", os: "27.0" }),
  );
  assert.equal(result.ok, true);
  assert.equal(result.name, "シミュ1");
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ1", simulator: "iPhone 17 Pro", os: "27.0" }]);
});

test("updateDeviceInMachineProfile: リネーム+横断(ios/android)重複はエラー", () => {
  const profile = {
    ios: { devices: [{ name: "シミュ1" }] },
    android: { devices: [{ name: "エミュ1" }] },
  };
  const result = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ name: "エミュ1" }));
  assert.equal(result.ok, false);
  assert.match(result.error, /エミュ1.*既に存在/);
});

test("updateDeviceInMachineProfile: 自分自身と同名(実質リネームなし)は OK", () => {
  const profile = { ios: { devices: [{ name: "シミュ1", simulator: "iPhone 16" }] } };
  const result = updateDeviceInMachineProfile(
    profile,
    "ios",
    "シミュ1",
    iosFields({ name: "シミュ1", simulator: "iPhone 17 Pro" }),
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios.devices, [{ name: "シミュ1", simulator: "iPhone 17 Pro" }]);
});

test("updateDeviceInMachineProfile: port の追加・削除・不正値", () => {
  const profile = { ios: { devices: [{ name: "シミュ1" }] } };

  const added = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ port: "8100" }));
  assert.equal(added.ok, true);
  assert.equal(added.object.ios.devices[0].port, 8100);

  const withPort = { ios: { devices: [{ name: "シミュ1", port: 8100 }] } };
  const removed = updateDeviceInMachineProfile(withPort, "ios", "シミュ1", iosFields({ port: "" }));
  assert.equal(removed.ok, true);
  assert.equal("port" in removed.object.ios.devices[0], false);

  const invalid1 = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ port: "not-a-number" }));
  assert.equal(invalid1.ok, false);
  assert.match(invalid1.error, /0〜65535/);

  const invalid2 = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ port: "65536" }));
  assert.equal(invalid2.ok, false);
  assert.match(invalid2.error, /0〜65535/);

  const invalid3 = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ port: "-1" }));
  assert.equal(invalid3.ok, false);
  assert.match(invalid3.error, /0〜65535/);

  const boundary = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ port: "65535" }));
  assert.equal(boundary.ok, true);
  assert.equal(boundary.object.ios.devices[0].port, 65535);
});

test("updateDeviceInMachineProfile: 空 name はエラー", () => {
  const profile = { ios: { devices: [{ name: "シミュ1" }] } };
  const result = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ name: "   " }));
  assert.equal(result.ok, false);
  assert.match(result.error, /デバイス名を入力/);
});

test("updateDeviceInMachineProfile: originalName が存在しなければエラー", () => {
  const profile = { ios: { devices: [{ name: "シミュ1" }] } };
  const result = updateDeviceInMachineProfile(profile, "ios", "存在しない", iosFields({ name: "存在しない" }));
  assert.equal(result.ok, false);
  assert.match(result.error, /見つかりませんでした/);

  const noSection = { note: "no ios here" };
  const result2 = updateDeviceInMachineProfile(noSection, "ios", "シミュ1", iosFields());
  assert.equal(result2.ok, false);
});

test("updateDeviceInMachineProfile: トップレベルがオブジェクトでなければエラー", () => {
  assert.equal(updateDeviceInMachineProfile(null, "ios", "x", iosFields()).ok, false);
  assert.equal(updateDeviceInMachineProfile(["ios"], "ios", "x", iosFields()).ok, false);
});

test("updateDeviceInMachineProfile: 未知キー(トップレベル・対象エントリ内)を保持する", () => {
  const profile = {
    someTopLevelKey: "keep-me",
    ios: {
      devices: [{ name: "シミュ1", simulator: "iPhone 16", customField: 123 }],
    },
  };
  const result = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ simulator: "iPhone 17 Pro" }));
  assert.equal(result.ok, true);
  assert.equal(result.object.someTopLevelKey, "keep-me");
  assert.deepEqual(result.object.ios.devices[0], {
    name: "シミュ1",
    simulator: "iPhone 17 Pro",
    customField: 123,
  });
});

test("updateDeviceInMachineProfile: 反対プラットフォームのフィールドには触れない", () => {
  const profile = { android: { devices: [{ name: "エミュ1", avd: "Pixel 9(Android 16)", strayIosField: "keep" }] } };
  const result = updateDeviceInMachineProfile(
    profile,
    "android",
    "エミュ1",
    { name: "エミュ1", simulator: "", os: "", udid: "", port: "", avd: "Pixel 9(Android 17)" },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.android.devices[0], {
    name: "エミュ1",
    avd: "Pixel 9(Android 17)",
    strayIosField: "keep",
  });
});

test("updateDeviceInMachineProfile: Android エントリに手書きの port キーがあっても保持する", () => {
  // Android のフォームは port フィールドを持たず常に空文字を送ってくるため、port の削除処理が
  // プラットフォーム分岐の外にあると avd 編集のついでに port キーが黙って消える(回帰テスト)。
  const profile = { android: { devices: [{ name: "エミュ1", avd: "Pixel 9(Android 16)", port: 5556 }] } };
  const result = updateDeviceInMachineProfile(
    profile,
    "android",
    "エミュ1",
    { name: "エミュ1", simulator: "", os: "", udid: "", port: "", avd: "Pixel 9(Android 17)" },
  );
  assert.equal(result.ok, true);
  assert.equal(result.object.android.devices[0].port, 5556);
});

test("updateDeviceInMachineProfile: iOS エントリに紛れ込んだ avd キーがあっても一切触らず保持する", () => {
  const profile = { ios: { devices: [{ name: "シミュ1", simulator: "iPhone 16", avd: "stray-avd-value" }] } };
  const result = updateDeviceInMachineProfile(profile, "ios", "シミュ1", iosFields({ simulator: "iPhone 17 Pro" }));
  assert.equal(result.ok, true);
  assert.equal(result.object.ios.devices[0].avd, "stray-avd-value");
});

test("updateDeviceInMachineProfile: Android の avd 更新(追加・削除)", () => {
  const profile = { android: { devices: [{ name: "エミュ1" }] } };
  const added = updateDeviceInMachineProfile(profile, "android", "エミュ1", {
    name: "エミュ1",
    simulator: "",
    os: "",
    udid: "",
    port: "",
    avd: "Pixel 9(Android 16)",
  });
  assert.equal(added.ok, true);
  assert.equal(added.object.android.devices[0].avd, "Pixel 9(Android 16)");

  const withAvd = { android: { devices: [{ name: "エミュ1", avd: "Pixel 9(Android 16)" }] } };
  const removed = updateDeviceInMachineProfile(withAvd, "android", "エミュ1", {
    name: "エミュ1",
    simulator: "",
    os: "",
    udid: "",
    port: "",
    avd: "",
  });
  assert.equal(removed.ok, true);
  assert.equal("avd" in removed.object.android.devices[0], false);
});

// ---- addDevicesToMachineProfile ----
// 「+既存から選択」モーダルの OK(machineDevicesSync)が add の追記部分に使う純粋関数
// (syncDevicesInMachineProfile 経由でも呼ばれる)。entries は MachineDeviceAddEntry
// (platform/name+オプショナルの simulator/os/udid/avd)の配列。

const IOS_ADD_ENTRY = {
  platform: "ios",
  name: "iPhone 17 Pro",
  simulator: "iPhone 17 Pro",
  os: "27.0",
  udid: "1C86FAKE-0000-0000-0000-000000000000",
};

const ANDROID_ADD_ENTRY = {
  platform: "android",
  name: "Pixel 9(Android 16)",
  avd: "Pixel_9",
};

test("addDevicesToMachineProfile: 基本追記(iOS1件をセクション末尾に追加)", () => {
  const result = addDevicesToMachineProfile({}, [IOS_ADD_ENTRY]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["iPhone 17 Pro"]);
  assert.deepEqual(result.object.ios.devices, [
    { name: "iPhone 17 Pro", simulator: "iPhone 17 Pro", os: "27.0", udid: "1C86FAKE-0000-0000-0000-000000000000" },
  ]);
});

test("addDevicesToMachineProfile: 複数一括(iOS+Androidをまとめて追加し、既存デバイスの後ろに追記する)", () => {
  const profile = {
    ios: { devices: [{ name: "既存シミュ", udid: "EXISTING" }] },
    android: { devices: [{ name: "既存エミュ", avd: "existing_avd" }] },
  };
  const result = addDevicesToMachineProfile(profile, [IOS_ADD_ENTRY, ANDROID_ADD_ENTRY]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["iPhone 17 Pro", "Pixel 9(Android 16)"]);
  assert.equal(result.object.ios.devices.length, 2);
  assert.equal(result.object.ios.devices[0].name, "既存シミュ");
  assert.equal(result.object.ios.devices[1].name, "iPhone 17 Pro");
  assert.equal(result.object.android.devices.length, 2);
  assert.equal(result.object.android.devices[1].name, "Pixel 9(Android 16)");
});

test("addDevicesToMachineProfile: 名前衝突は既存デバイス名(ios/android横断)と重複しなくなるまで「名前 (2)」「名前 (3)」…とサフィックスを付ける", () => {
  const profile = {
    ios: { devices: [{ name: "iPhone 17 Pro" }] },
    android: { devices: [{ name: "iPhone 17 Pro (2)" }] }, // ios/android 横断で衝突判定するため android 側にも既存名を置く
  };
  const result = addDevicesToMachineProfile(profile, [IOS_ADD_ENTRY]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["iPhone 17 Pro (3)"]);
  assert.equal(result.object.ios.devices[1].name, "iPhone 17 Pro (3)");
});

test("addDevicesToMachineProfile: 同一バッチ内の名前衝突も自動サフィックスで救済する", () => {
  const result = addDevicesToMachineProfile({}, [IOS_ADD_ENTRY, { ...IOS_ADD_ENTRY, udid: "OTHER-UDID" }]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["iPhone 17 Pro", "iPhone 17 Pro (2)"]);
  assert.equal(result.object.ios.devices[0].name, "iPhone 17 Pro");
  assert.equal(result.object.ios.devices[1].name, "iPhone 17 Pro (2)");
});

test("addDevicesToMachineProfile: エントリは name + 非空のオプショナルフィールドのみをキーとして構築する(空文字/undefinedは持たせない)", () => {
  const undefinedFields = addDevicesToMachineProfile({}, [{ platform: "android", name: "エミュ1" }]);
  assert.equal(undefinedFields.ok, true);
  assert.deepEqual(undefinedFields.object.android.devices, [{ name: "エミュ1" }]);

  // オプショナルフィールドが空文字で明示的に渡された場合もキー自体を持たせない。
  const emptyStringFields = addDevicesToMachineProfile({}, [
    { platform: "ios", name: "シミュ1", simulator: "", os: "", udid: "" },
  ]);
  assert.equal(emptyStringFields.ok, true);
  assert.deepEqual(emptyStringFields.object.ios.devices, [{ name: "シミュ1" }]);
});

test("addDevicesToMachineProfile: 未知キー(トップレベル・既存セクション・既存デバイスエントリ)を保持する", () => {
  const profile = {
    customTopKey: "keep-me",
    ios: {
      customSectionKey: "keep-me-too",
      devices: [{ name: "既存", udid: "EXISTING", customDeviceKey: "keep-me-three" }],
    },
  };
  const result = addDevicesToMachineProfile(profile, [IOS_ADD_ENTRY]);
  assert.equal(result.ok, true);
  assert.equal(result.object.customTopKey, "keep-me");
  assert.equal(result.object.ios.customSectionKey, "keep-me-too");
  assert.equal(result.object.ios.devices[0].customDeviceKey, "keep-me-three");
});

test("addDevicesToMachineProfile: トップレベルがオブジェクトでなければ(配列含む)エラー", () => {
  assert.equal(addDevicesToMachineProfile(null, [IOS_ADD_ENTRY]).ok, false);
  assert.equal(addDevicesToMachineProfile([{ ios: {} }], [IOS_ADD_ENTRY]).ok, false);
  assert.equal(addDevicesToMachineProfile("string", [IOS_ADD_ENTRY]).ok, false);
});

// ---- syncDevicesInMachineProfile ----
// 「+既存から選択」モーダルの OK(machineDevicesSync)が使う純粋関数。remove を
// removeDeviceFromMachineProfile で先に適用してから add を addDevicesToMachineProfile で
// 追記する合成関数(削除→追加の順序であることを、名前再利用のテストで確認する)。

test("syncDevicesInMachineProfile: 追加のみ(remove:[])は addDevicesToMachineProfile と同じ結果 + removed:0", () => {
  const result = syncDevicesInMachineProfile({}, [IOS_ADD_ENTRY], []);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["iPhone 17 Pro"]);
  assert.equal(result.removed, 0);
  assert.deepEqual(result.object.ios.devices, [
    { name: "iPhone 17 Pro", simulator: "iPhone 17 Pro", os: "27.0", udid: "1C86FAKE-0000-0000-0000-000000000000" },
  ]);
});

test("syncDevicesInMachineProfile: 削除のみ(add:[])は指定名を除去し removed:1", () => {
  const profile = { ios: { devices: [{ name: "既存デバイス名", udid: "EXISTING" }, { name: "残る" }] } };
  const result = syncDevicesInMachineProfile(profile, [], ["既存デバイス名"]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, []);
  assert.equal(result.removed, 1);
  assert.deepEqual(result.object.ios.devices, [{ name: "残る" }]);
});

test("syncDevicesInMachineProfile: 追加+削除を1回で適用する", () => {
  const profile = {
    ios: { devices: [{ name: "削除対象", udid: "EXISTING" }] },
    android: { devices: [{ name: "既存エミュ", avd: "existing_avd" }] },
  };
  const result = syncDevicesInMachineProfile(profile, [ANDROID_ADD_ENTRY], ["削除対象"]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["Pixel 9(Android 16)"]);
  assert.equal(result.removed, 1);
  assert.deepEqual(result.object.ios.devices, []);
  assert.equal(result.object.android.devices.length, 2);
  assert.equal(result.object.android.devices[0].name, "既存エミュ");
  assert.equal(result.object.android.devices[1].name, "Pixel 9(Android 16)");
});

test("syncDevicesInMachineProfile: 削除→追加の名前再利用は衝突しない(除去後に一意性判定するため)", () => {
  const profile = { ios: { devices: [{ name: "X", udid: "EXISTING" }] } };
  const result = syncDevicesInMachineProfile(profile, [{ ...IOS_ADD_ENTRY, name: "X" }], ["X"]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["X"]); // 先に削除されるため "X (2)" にはならない
  assert.equal(result.removed, 1);
  assert.equal(result.object.ios.devices.length, 1);
  assert.equal(result.object.ios.devices[0].name, "X");
});

test("syncDevicesInMachineProfile: remove に存在しない名前は ok:true・removed:0 でスキップされる", () => {
  const profile = { ios: { devices: [{ name: "残る" }] } };
  const result = syncDevicesInMachineProfile(profile, [], ["存在しない名前"]);
  assert.equal(result.ok, true);
  assert.equal(result.removed, 0);
  assert.deepEqual(result.object.ios.devices, [{ name: "残る" }]);
});

test("syncDevicesInMachineProfile: 未知キー(トップレベル・セクション・デバイスエントリ)を保持する", () => {
  const profile = {
    customTopKey: "keep-me",
    ios: {
      customSectionKey: "keep-me-too",
      devices: [{ name: "削除対象", udid: "EXISTING", customDeviceKey: "keep-me-three" }, { name: "残る" }],
    },
  };
  const result = syncDevicesInMachineProfile(profile, [ANDROID_ADD_ENTRY], ["削除対象"]);
  assert.equal(result.ok, true);
  assert.equal(result.object.customTopKey, "keep-me");
  assert.equal(result.object.ios.customSectionKey, "keep-me-too");
  assert.deepEqual(result.object.ios.devices, [{ name: "残る" }]);
  assert.equal(result.object.android.devices[0].name, "Pixel 9(Android 16)");
});

test("syncDevicesInMachineProfile: トップレベルがオブジェクトでなければ(配列含む)エラー", () => {
  assert.equal(syncDevicesInMachineProfile(null, [], ["x"]).ok, false);
  assert.equal(syncDevicesInMachineProfile([{ ios: {} }], [], ["x"]).ok, false);
  assert.equal(syncDevicesInMachineProfile("string", [], ["x"]).ok, false);
});

// ---- parseRunProfileForForm ----

test("parseRunProfileForForm: 正常な値は11フィールドをそのまま読み取る", () => {
  const parsed = parseRunProfileForForm({
    machine: "M1 Max",
    app: "sampleapp",
    devices: [{ name: "シミュ1" }, { name: "エミュ1" }],
    heal: true,
    iosInappEngine: false,
    reportDir: "reports",
    defaultTimeout: 10,
    wipeDataOnBloat: false,
    wipeDataThresholdGB: 1.5,
    locale: "en_US",
    record: true,
  });
  assert.deepEqual(parsed, {
    machine: "M1 Max",
    app: "sampleapp",
    devices: ["シミュ1", "エミュ1"],
    heal: true,
    iosInappEngine: false,
    reportDir: "reports",
    defaultTimeout: "10",
    wipeDataOnBloat: false,
    wipeDataThresholdGB: "1.5",
    locale: "en_US",
    record: true,
  });
});

test("parseRunProfileForForm: 欠落キーは既定値(machine/app/reportDir/locale=''、devices=[]、heal=false、iosInappEngine=true、defaultTimeout=''、wipeDataOnBloat=true、wipeDataThresholdGB=''、record=false)", () => {
  const parsed = parseRunProfileForForm({});
  assert.deepEqual(parsed, {
    machine: "",
    app: "",
    devices: [],
    heal: false,
    iosInappEngine: true,
    reportDir: "",
    defaultTimeout: "",
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "",
    locale: "",
    record: false,
  });
});

test("parseRunProfileForForm: 型不正のキーは既定値扱い(machine が数値、heal が文字列、record が文字列 等)", () => {
  const parsed = parseRunProfileForForm({
    machine: 123,
    app: null,
    devices: "not-an-array",
    heal: "true",
    iosInappEngine: "false",
    reportDir: false,
    defaultTimeout: {},
    wipeDataOnBloat: "false",
    wipeDataThresholdGB: {},
    locale: 123,
    record: "true",
  });
  assert.deepEqual(parsed, {
    machine: "",
    app: "",
    devices: [],
    heal: false,
    iosInappEngine: true,
    reportDir: "",
    defaultTimeout: "",
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "",
    locale: "",
    record: false,
  });
});

test("parseRunProfileForForm: devices は name が非文字列/オブジェクトでない要素をスキップする", () => {
  const parsed = parseRunProfileForForm({
    devices: [{ name: "シミュ1" }, { name: 123 }, "not-an-object", { other: "x" }, { name: "エミュ1" }],
  });
  assert.deepEqual(parsed.devices, ["シミュ1", "エミュ1"]);
});

test("parseRunProfileForForm: defaultTimeout が string ならそのまま返す(整数化しない)", () => {
  const parsed = parseRunProfileForForm({ defaultTimeout: "10.5" });
  assert.equal(parsed.defaultTimeout, "10.5");
});

test("parseRunProfileForForm: wipeDataThresholdGB は number なら String() 化、string ならそのまま返す", () => {
  assert.equal(parseRunProfileForForm({ wipeDataThresholdGB: 1 }).wipeDataThresholdGB, "1");
  assert.equal(parseRunProfileForForm({ wipeDataThresholdGB: "2.5" }).wipeDataThresholdGB, "2.5");
});

test("parseRunProfileForForm: locale は string ならそのまま返し、非 string(number/object)は既定値''", () => {
  assert.equal(parseRunProfileForForm({ locale: "en_US" }).locale, "en_US");
  assert.equal(parseRunProfileForForm({ locale: 123 }).locale, "");
  assert.equal(parseRunProfileForForm({ locale: {} }).locale, "");
});

test("parseRunProfileForForm: record は boolean ならそのまま返し、欠落/非 boolean は既定値 false", () => {
  assert.equal(parseRunProfileForForm({ record: true }).record, true);
  assert.equal(parseRunProfileForForm({ record: false }).record, false);
  assert.equal(parseRunProfileForForm({}).record, false);
  assert.equal(parseRunProfileForForm({ record: "true" }).record, false);
});

test("parseRunProfileForForm: トップレベルが非オブジェクト(配列含む)なら null", () => {
  assert.equal(parseRunProfileForForm(null), null);
  assert.equal(parseRunProfileForForm("string"), null);
  assert.equal(parseRunProfileForForm([{ app: "a" }]), null);
});

// ---- parseAppProfileForForm ----
// common は表示名(appName)+自動インストール(autoInstall。true のときだけ "true"、それ以外
// [false/欠落/型不正]は既定=無効を表す "false")の2フィールド、ios/android は表示名・アプリID・
// パッケージパスの3フィールド(autoInstall は common に一本化されたため持たない。2026-07-11 指示)。

test("parseAppProfileForForm: 正常な値を読み取る(common は表示名+自動インストール、ios/android は3フィールド)", () => {
  const parsed = parseAppProfileForForm({
    common: { appName: "サンプルアプリ", app: "com.example.sampleapp", appPath: "path/to.app", autoInstall: true },
    ios: { appName: "サンプル(iOS)", app: "com.example.sampleapp.ios", appPath: "path/to-ios.app", autoInstall: false },
    android: {
      appName: "サンプル(Android)",
      app: "com.example.sampleapp.android",
      appPath: "path/to.apk",
      autoInstall: true,
    },
  });
  assert.deepEqual(parsed, {
    // common の app/appPath は廃止のため読み取らない(appName+autoInstall のみ反映される)。
    common: { appName: "サンプルアプリ", autoInstall: "true" },
    // ios/android の autoInstall は common に一本化されたため読み取らない(残っていても無視)。
    ios: { appName: "サンプル(iOS)", app: "com.example.sampleapp.ios", appPath: "path/to-ios.app" },
    android: {
      appName: "サンプル(Android)",
      app: "com.example.sampleapp.android",
      appPath: "path/to.apk",
    },
  });
});

test("parseAppProfileForForm: セクション欠落は空のセクションとして読み取る(common の autoInstall は既定 'false')", () => {
  const parsed = parseAppProfileForForm({});
  const emptyPlatform = { appName: "", app: "", appPath: "" };
  assert.deepEqual(parsed, { common: { appName: "", autoInstall: "false" }, ios: emptyPlatform, android: emptyPlatform });
});

test("parseAppProfileForForm: セクションが非オブジェクト(配列含む)なら空のセクション扱い", () => {
  const parsed = parseAppProfileForForm({ common: "invalid", ios: null, android: ["a"] });
  const emptyPlatform = { appName: "", app: "", appPath: "" };
  assert.deepEqual(parsed, { common: { appName: "", autoInstall: "false" }, ios: emptyPlatform, android: emptyPlatform });
});

test("parseAppProfileForForm: フィールドの型不正は既定値扱い(appName が数値、app/appPath が欠落 等)", () => {
  const parsed = parseAppProfileForForm({
    common: { appName: 123, app: "irrelevant", autoInstall: "true" }, // autoInstall は文字列(型不正)なので既定 false 扱い
    ios: { appName: 123, app: null },
  });
  assert.deepEqual(parsed.common, { appName: "", autoInstall: "false" });
  assert.deepEqual(parsed.ios, { appName: "", app: "", appPath: "" });
});

test("parseAppProfileForForm: common の autoInstall は true のときだけ 'true'、false/欠落/型不正は既定の 'false'", () => {
  assert.equal(parseAppProfileForForm({ common: { autoInstall: true } }).common.autoInstall, "true");
  assert.equal(parseAppProfileForForm({ common: { autoInstall: false } }).common.autoInstall, "false");
  assert.equal(parseAppProfileForForm({ common: {} }).common.autoInstall, "false");
  assert.equal(parseAppProfileForForm({ common: { autoInstall: "true" } }).common.autoInstall, "false"); // 文字列は型不正
});

test("parseAppProfileForForm: ios/android に残った autoInstall は common に一本化されたため読み取らない(無視される)", () => {
  const parsed = parseAppProfileForForm({ ios: { autoInstall: true } });
  assert.equal("autoInstall" in parsed.ios, false);
});

test("parseAppProfileForForm: トップレベルが非オブジェクト(配列含む)なら null", () => {
  assert.equal(parseAppProfileForForm(null), null);
  assert.equal(parseAppProfileForForm("string"), null);
  assert.equal(parseAppProfileForForm([{ common: {} }]), null);
});

// ---- updateRunProfileInObject ----

const BASE_RUN_PROFILE_FIELDS = {
  machine: "M1 Max",
  app: "sampleapp",
  devices: ["シミュ1", "エミュ1"],
  heal: false,
  iosInappEngine: true,
  reportDir: "reports",
  defaultTimeout: "10",
  wipeDataOnBloat: true,
  wipeDataThresholdGB: "1",
  locale: "ja_JP",
  record: false,
};

test("updateRunProfileInObject: 基本更新(machine/app/heal/iosInappEngine/wipeDataOnBloat/reportDir/defaultTimeout)", () => {
  const result = updateRunProfileInObject({ app: "old", devices: [], heal: false, reportDir: "old" }, BASE_RUN_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.machine, "M1 Max");
  assert.equal(result.object.app, "sampleapp");
  assert.equal(result.object.heal, false);
  assert.equal(result.object.iosInappEngine, true);
  assert.equal(result.object.wipeDataOnBloat, true);
  assert.equal(result.object.wipeDataThresholdGB, 1);
  assert.equal(result.object.reportDir, "reports");
  assert.equal(result.object.defaultTimeout, 10);
  assert.equal(result.object.locale, "ja_JP");
  assert.deepEqual(result.object.devices, [{ name: "シミュ1" }, { name: "エミュ1" }]);
  assert.equal("record" in result.object, false); // record:false はキーを書かない
});

test("updateRunProfileInObject: record は true のときのみ書き込み、false なら既存キーごと削除する", () => {
  const enabled = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, record: true });
  assert.equal(enabled.ok, true);
  assert.equal(enabled.object.record, true);

  const disabledFromScratch = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, record: false });
  assert.equal(disabledFromScratch.ok, true);
  assert.equal("record" in disabledFromScratch.object, false);

  const disabledFromExisting = updateRunProfileInObject({ record: true }, { ...BASE_RUN_PROFILE_FIELDS, record: false });
  assert.equal(disabledFromExisting.ok, true);
  assert.equal("record" in disabledFromExisting.object, false);
});

test("updateRunProfileInObject: wipeDataOnBloat は常時書き込み、wipeDataThresholdGB は空文字でキー削除、正の数(小数許容)で number 化、不正値でエラー", () => {
  const offResult = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, wipeDataOnBloat: false });
  assert.equal(offResult.ok, true);
  assert.equal(offResult.object.wipeDataOnBloat, false);

  const removed = updateRunProfileInObject(
    { wipeDataThresholdGB: 2 },
    { ...BASE_RUN_PROFILE_FIELDS, wipeDataThresholdGB: "" },
  );
  assert.equal(removed.ok, true);
  assert.equal("wipeDataThresholdGB" in removed.object, false);

  const decimal = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, wipeDataThresholdGB: "1.5" });
  assert.equal(decimal.ok, true);
  assert.equal(decimal.object.wipeDataThresholdGB, 1.5);
  assert.equal(typeof decimal.object.wipeDataThresholdGB, "number");

  for (const invalid of ["0", "-1", "abc"]) {
    const result = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, wipeDataThresholdGB: invalid });
    assert.equal(result.ok, false, `wipeDataThresholdGB=${invalid} は不正値としてエラーになるべき`);
    assert.match(result.error, /wipeDataThresholdGB/);
  }
});

test("updateRunProfileInObject: locale は空文字でキー削除、'en-US'/'ja_JP' は文字列のまま書き込み、不正値でエラー", () => {
  const removed = updateRunProfileInObject({ locale: "ja_JP" }, { ...BASE_RUN_PROFILE_FIELDS, locale: "" });
  assert.equal(removed.ok, true);
  assert.equal("locale" in removed.object, false);

  const enUs = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, locale: "en-US" });
  assert.equal(enUs.ok, true);
  assert.equal(enUs.object.locale, "en-US");
  assert.equal(typeof enUs.object.locale, "string");

  const jaJp = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, locale: "ja_JP" });
  assert.equal(jaJp.ok, true);
  assert.equal(jaJp.object.locale, "ja_JP");

  for (const invalid of ["ja JP", "日本語"]) {
    const result = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, locale: invalid });
    assert.equal(result.ok, false, `locale=${invalid} は不正値としてエラーになるべき`);
    assert.match(result.error, /locale/);
  }
});

test("updateRunProfileInObject: machine/app/reportDir は空文字ならキー削除する", () => {
  const result = updateRunProfileInObject(
    { machine: "M1 Max", app: "sampleapp", devices: [], heal: false, reportDir: "reports" },
    { ...BASE_RUN_PROFILE_FIELDS, machine: "", app: "", reportDir: "" },
  );
  assert.equal(result.ok, true);
  assert.equal("machine" in result.object, false);
  assert.equal("app" in result.object, false);
  assert.equal("reportDir" in result.object, false);
});

test("updateRunProfileInObject: defaultTimeout は空文字でキー削除、正の整数文字列で number 化、不正値でエラー", () => {
  const removed = updateRunProfileInObject(
    { defaultTimeout: 10 },
    { ...BASE_RUN_PROFILE_FIELDS, defaultTimeout: "" },
  );
  assert.equal(removed.ok, true);
  assert.equal("defaultTimeout" in removed.object, false);

  const added = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, defaultTimeout: "30" });
  assert.equal(added.ok, true);
  assert.equal(added.object.defaultTimeout, 30);
  assert.equal(typeof added.object.defaultTimeout, "number");

  for (const invalid of ["0", "-1", "1.5", "abc"]) {
    const result = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, defaultTimeout: invalid });
    assert.equal(result.ok, false, `defaultTimeout=${invalid} は不正値としてエラーになるべき`);
    assert.match(result.error, /defaultTimeout/);
  }
});

test("updateRunProfileInObject: devices は既存の同名エントリ(未知キー込み)を再利用し、新規名は{name}のみ追加する", () => {
  const profile = {
    devices: [
      { name: "シミュ1", note: "keep-me" },
      { name: "旧デバイス" },
    ],
  };
  const result = updateRunProfileInObject(profile, { ...BASE_RUN_PROFILE_FIELDS, devices: ["シミュ1", "新デバイス"] });
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [{ name: "シミュ1", note: "keep-me" }, { name: "新デバイス" }]);
});

test("updateRunProfileInObject: devices は fields.devices の順序で再構成する", () => {
  const profile = { devices: [{ name: "A" }, { name: "B" }] };
  const result = updateRunProfileInObject(profile, { ...BASE_RUN_PROFILE_FIELDS, devices: ["B", "A"] });
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [{ name: "B" }, { name: "A" }]);
});

test("updateRunProfileInObject: 未知キー(トップレベル)を保持する", () => {
  const profile = { app: "old", devices: [], futureFeature: { nested: true } };
  const result = updateRunProfileInObject(profile, BASE_RUN_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.futureFeature, { nested: true });
});

test("updateRunProfileInObject: devices 要素内の未知キーを保持する(再利用時)", () => {
  const profile = { devices: [{ name: "シミュ1", customFlag: true, nested: { a: 1 } }] };
  const result = updateRunProfileInObject(profile, { ...BASE_RUN_PROFILE_FIELDS, devices: ["シミュ1"] });
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [{ name: "シミュ1", customFlag: true, nested: { a: 1 } }]);
});

test("updateRunProfileInObject: トップレベルがオブジェクトでなければ(配列含む)エラー", () => {
  assert.equal(updateRunProfileInObject(null, BASE_RUN_PROFILE_FIELDS).ok, false);
  assert.equal(updateRunProfileInObject([{ app: "a" }], BASE_RUN_PROFILE_FIELDS).ok, false);
  assert.equal(updateRunProfileInObject("string", BASE_RUN_PROFILE_FIELDS).ok, false);
});

// ---- updateAppProfileInObject ----
// common は表示名(appName)+自動インストール(autoInstall。"true" は boolean true をセット、
// "false" は既定[無効]と同値なのでキー削除)を書き込む(app/appPath は廃止に伴い常に削除)。
// ios/android は表示名・アプリID・パッケージパスのみを書き込む(autoInstall は common に
// 一本化されたため、残っていても廃止に伴い常に削除する。2026-07-11 指示)。

const BASE_APP_PROFILE_FIELDS = {
  common: { appName: "サンプルアプリ", autoInstall: "false" },
  ios: { appName: "", app: "", appPath: "" },
  android: { appName: "", app: "", appPath: "" },
};

test("updateAppProfileInObject: 基本更新(common は表示名+自動インストール)", () => {
  const result = updateAppProfileInObject({}, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  // autoInstall は "false"(既定と同値)なのでキー自体を持たない。
  assert.deepEqual(result.object.common, { appName: "サンプルアプリ" });
});

test("updateAppProfileInObject: common の appName は空文字ならキー削除する", () => {
  const result = updateAppProfileInObject(
    { common: { appName: "old" } },
    { ...BASE_APP_PROFILE_FIELDS, common: { appName: "", autoInstall: "false" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, {});
});

test("updateAppProfileInObject: common に残った app/appPath は廃止に伴い常に削除する", () => {
  const result = updateAppProfileInObject(
    { common: { appName: "old", app: "old.app", appPath: "old/path" } },
    BASE_APP_PROFILE_FIELDS,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, { appName: "サンプルアプリ" });
});

test("updateAppProfileInObject: common の autoInstall は2値('true' は boolean true をセット/'false' はキー削除)", () => {
  const removed = updateAppProfileInObject(
    { common: { autoInstall: true } },
    { ...BASE_APP_PROFILE_FIELDS, common: { appName: "", autoInstall: "false" } },
  );
  assert.equal("autoInstall" in removed.object.common, false);

  const trueResult = updateAppProfileInObject({}, { ...BASE_APP_PROFILE_FIELDS, common: { appName: "", autoInstall: "true" } });
  assert.equal(trueResult.object.common.autoInstall, true);
});

test("updateAppProfileInObject: ios/android の appName/app/appPath は空文字ならキー削除する", () => {
  const result = updateAppProfileInObject(
    { ios: { appName: "old", app: "old", appPath: "old" } },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: ios/android に残った autoInstall は common への一本化に伴い常に削除する", () => {
  const result = updateAppProfileInObject(
    { ios: { autoInstall: true } },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: 元に無い common セクションは appName 空・autoInstall 'false' のままなら作らない", () => {
  const result = updateAppProfileInObject({}, { ...BASE_APP_PROFILE_FIELDS, common: { appName: "", autoInstall: "false" } });
  assert.equal(result.ok, true);
  assert.equal("common" in result.object, false);
});

test("updateAppProfileInObject: 元に無い ios/android セクションは全フィールド既定値のままなら作らない", () => {
  const result = updateAppProfileInObject({}, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal("ios" in result.object, false);
  assert.equal("android" in result.object, false);
});

test("updateAppProfileInObject: 元に無いセクションでも1つでも値があれば作る(common は appName または autoInstall 'true'、ios/android は appName/app/appPath のいずれか)", () => {
  const commonResult = updateAppProfileInObject({}, BASE_APP_PROFILE_FIELDS);
  assert.deepEqual(commonResult.object.common, { appName: "サンプルアプリ" });

  const byCommonAutoInstall = updateAppProfileInObject(
    {},
    { ...BASE_APP_PROFILE_FIELDS, common: { appName: "", autoInstall: "true" } },
  );
  assert.deepEqual(byCommonAutoInstall.object.common, { autoInstall: true });

  const byField = updateAppProfileInObject(
    {},
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "com.example.ios", appPath: "" } },
  );
  assert.deepEqual(byField.object.ios, { app: "com.example.ios" });
});

test("updateAppProfileInObject: 既存の空セクションは空のまま保持する", () => {
  const result = updateAppProfileInObject(
    { ios: {} },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: 未知キー(トップレベル)を保持する", () => {
  const profile = { common: {}, customTopKey: "keep-me" };
  const result = updateAppProfileInObject(profile, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.customTopKey, "keep-me");
});

test("updateAppProfileInObject: 未知キー(セクション内)を保持する", () => {
  const profile = { common: { customKey: "keep-me", appName: "old" } };
  const result = updateAppProfileInObject(profile, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.common.customKey, "keep-me");
});

test("updateAppProfileInObject: トップレベルがオブジェクトでなければ(配列含む)エラー", () => {
  assert.equal(updateAppProfileInObject(null, BASE_APP_PROFILE_FIELDS).ok, false);
  assert.equal(updateAppProfileInObject([{ common: {} }], BASE_APP_PROFILE_FIELDS).ok, false);
  assert.equal(updateAppProfileInObject("string", BASE_APP_PROFILE_FIELDS).ok, false);
});

// ---- isDeviceCatalogJson ----

const VALID_DEVICE_CATALOG = {
  android: {
    available: true,
    error: null,
    models: [{ id: "pixel_9_pro", name: "Pixel 9 Pro" }],
    systemImages: [
      {
        abi: "arm64-v8a",
        apiLevel: 37,
        package: "system-images;android-37;google_apis;arm64-v8a",
        tag: "google_apis",
        versionName: "Android 17",
      },
    ],
  },
  ios: {
    available: true,
    error: null,
    deviceTypes: [
      { identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", name: "iPhone 17 Pro", productFamily: "iPhone" },
    ],
    runtimes: [{ identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0" }],
  },
};

test("isDeviceCatalogJson: 正常な値を true と判定する", () => {
  assert.equal(isDeviceCatalogJson(VALID_DEVICE_CATALOG), true);
});

test("isDeviceCatalogJson: available:false 側は models/deviceTypes 等が空配列でも true(error に理由がある想定)", () => {
  const value = {
    android: { available: false, error: "adb が見つかりません", models: [], systemImages: [] },
    ios: VALID_DEVICE_CATALOG.ios,
  };
  assert.equal(isDeviceCatalogJson(value), true);
});

test("isDeviceCatalogJson: トップレベルの android/ios 欠落や非オブジェクトは false", () => {
  assert.equal(isDeviceCatalogJson(null), false);
  assert.equal(isDeviceCatalogJson({}), false);
  assert.equal(isDeviceCatalogJson({ android: VALID_DEVICE_CATALOG.android }), false);
});

test("isDeviceCatalogJson: 配列要素のフィールド欠落/型不一致は全体を false にする", () => {
  const badModel = structuredClone(VALID_DEVICE_CATALOG);
  badModel.android.models = [{ id: "pixel_9_pro" }]; // name 欠落
  assert.equal(isDeviceCatalogJson(badModel), false);

  const badSystemImage = structuredClone(VALID_DEVICE_CATALOG);
  badSystemImage.android.systemImages[0].apiLevel = "37"; // 数値でない
  assert.equal(isDeviceCatalogJson(badSystemImage), false);

  const badDeviceType = structuredClone(VALID_DEVICE_CATALOG);
  delete badDeviceType.ios.deviceTypes[0].productFamily;
  assert.equal(isDeviceCatalogJson(badDeviceType), false);

  const badRuntime = structuredClone(VALID_DEVICE_CATALOG);
  badRuntime.ios.runtimes[0].version = 27; // 数値でない
  assert.equal(isDeviceCatalogJson(badRuntime), false);
});

test("isDeviceCatalogJson: available が boolean でない、error が string/null でないと false", () => {
  const badAvailable = structuredClone(VALID_DEVICE_CATALOG);
  badAvailable.android.available = "true";
  assert.equal(isDeviceCatalogJson(badAvailable), false);

  const badError = structuredClone(VALID_DEVICE_CATALOG);
  badError.ios.error = 123;
  assert.equal(isDeviceCatalogJson(badError), false);
});

// ---- isInstalledDevicesJson ----
// `ftester api installed-devices` の stdout(「+既存から選択」モーダルが使う)。

const VALID_INSTALLED_DEVICES = {
  android: {
    available: true,
    avds: [
      { displayName: "Pixel 9(Android 16)", id: "Pixel_9" },
      { displayName: "Pixel_7a", id: "Pixel_7a" }, // displayName===id もありうる(自動生成名のまま)
    ],
    error: null,
  },
  ios: {
    available: true,
    devices: [{ name: "iPhone 17 Pro", os: "27.0", udid: "1C86FAKE-0000-0000-0000-000000000000" }],
    error: null,
  },
};

test("isInstalledDevicesJson: 正常な値を true と判定する", () => {
  assert.equal(isInstalledDevicesJson(VALID_INSTALLED_DEVICES), true);
});

test("isInstalledDevicesJson: available:false 側は avds/devices が空配列でも true(error に理由がある想定)", () => {
  const value = {
    android: { available: false, error: "Android SDK が見つかりません", avds: [] },
    ios: VALID_INSTALLED_DEVICES.ios,
  };
  assert.equal(isInstalledDevicesJson(value), true);
});

test("isInstalledDevicesJson: トップレベルの android/ios 欠落や非オブジェクトは false", () => {
  assert.equal(isInstalledDevicesJson(null), false);
  assert.equal(isInstalledDevicesJson({}), false);
  assert.equal(isInstalledDevicesJson({ android: VALID_INSTALLED_DEVICES.android }), false);
});

test("isInstalledDevicesJson: 配列要素のフィールド欠落/型不一致は全体を false にする", () => {
  const badAvd = structuredClone(VALID_INSTALLED_DEVICES);
  badAvd.android.avds = [{ id: "Pixel_9" }]; // displayName 欠落
  assert.equal(isInstalledDevicesJson(badAvd), false);

  const badIosDevice = structuredClone(VALID_INSTALLED_DEVICES);
  delete badIosDevice.ios.devices[0].udid;
  assert.equal(isInstalledDevicesJson(badIosDevice), false);
});

test("isInstalledDevicesJson: available が boolean でない、error が string/null でないと false", () => {
  const badAvailable = structuredClone(VALID_INSTALLED_DEVICES);
  badAvailable.android.available = "true";
  assert.equal(isInstalledDevicesJson(badAvailable), false);

  const badError = structuredClone(VALID_INSTALLED_DEVICES);
  badError.ios.error = 123;
  assert.equal(isInstalledDevicesJson(badError), false);
});

// ---- isCreateDeviceEvent ----

test("isCreateDeviceEvent: log/finished(ok:true,device あり/ok:false,device なし)の正常な値を true と判定する", () => {
  assert.equal(isCreateDeviceEvent({ kind: "log", message: "作成しています..." }), true);
  assert.equal(
    isCreateDeviceEvent({
      kind: "finished",
      ok: true,
      error: null,
      device: { avd: null, name: "シミュ1", udid: "ABCDEFGH-1234" },
    }),
    true,
  );
  assert.equal(isCreateDeviceEvent({ kind: "finished", ok: false, error: "失敗しました", device: null }), true);
});

test("isCreateDeviceEvent: finished は device フィールド省略でも true(失敗時に省略されうる契約のため)", () => {
  assert.equal(isCreateDeviceEvent({ kind: "finished", ok: false, error: "失敗しました" }), true);
});

test("isCreateDeviceEvent: 未知のkind・フィールド欠落/型不一致は false", () => {
  assert.equal(isCreateDeviceEvent({ kind: "unknown" }), false);
  assert.equal(isCreateDeviceEvent({ kind: "log", message: 123 }), false);
  assert.equal(isCreateDeviceEvent({ kind: "finished", ok: "true", error: null }), false);
  // device が非 null オブジェクトの場合、avd/udid は null か string(欠落は不可)、name は必須。
  assert.equal(
    isCreateDeviceEvent({ kind: "finished", ok: true, error: null, device: { name: "n" } }),
    false, // avd/udid 欠落
  );
  assert.equal(
    isCreateDeviceEvent({ kind: "finished", ok: true, error: null, device: { avd: null, udid: null } }),
    false, // name 欠落
  );
  assert.equal(isCreateDeviceEvent(null), false);
});

// ---- 統合: mock-device-op.mjs → NdjsonParser → isDeviceOpEvent ----

test("統合: mock-device-op.mjs device-up(成功)は log→log→finished(ok:true) の順で exit 0", async () => {
  const { events, exitCode } = await runMockDeviceOp(["device-up", "--name", "シミュ1"]);
  assert.equal(exitCode, 0);
  assert.deepEqual(
    events.map((e) => e.kind),
    ["log", "log", "finished"],
  );
  assert.equal(events[2].ok, true);
  assert.equal(events[2].error, null);
});

test("統合: mock-device-op.mjs device-down --fail は log→finished(ok:false) の順で exit 1", async () => {
  const { events, exitCode } = await runMockDeviceOp(["device-down", "--name", "シミュ2", "--fail"]);
  assert.equal(exitCode, 1);
  assert.deepEqual(
    events.map((e) => e.kind),
    ["log", "finished"],
  );
  assert.equal(events[1].ok, false);
  assert.ok(events[1].error && events[1].error.length > 0);
});

/** mock-device-op.mjs を spawn し、stdout を NdjsonParser → isDeviceOpEvent に通して収集したイベント配列を返す。 */
function runMockDeviceOp(mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_DEVICE_OP, ...mockArgs], {
      cwd: path.dirname(MOCK_DEVICE_OP),
      stdio: ["ignore", "pipe", "pipe"],
    });

    const events = [];
    const parser = new NdjsonParser(
      (value) => {
        if (isDeviceOpEvent(value)) {
          events.push(value);
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error("mock-device-op.mjs からの応答がタイムアウトしました"));
    }, 5000);

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", (exitCode) => {
      clearTimeout(timer);
      parser.end();
      resolve({ events, exitCode });
    });
  });
}

// ---- 統合: mock-monitor.mjs → NdjsonParser → monitorModel ----

test("統合: mock-monitor.mjs(success パターン)の出力を NdjsonParser → monitorModel に通すと devices→frame×3→deviceError の順のメッセージ列になる", async () => {
  const messages = await runMockMonitorThroughPipeline(["--pattern", "success"], 5);

  assert.equal(messages.length, 5);
  assert.deepEqual(
    messages.map((m) => m.type),
    ["devices", "frame", "frame", "frame", "deviceError"],
  );

  assert.equal(messages[0].devices.length, 2);
  assert.equal(messages[0].devices[0].id, "ios:シミュ1");
  assert.equal(messages[0].devices[0].state, "connected");
  assert.equal(messages[0].devices[1].state, "booted");

  for (let i = 0; i < 3; i += 1) {
    assert.equal(messages[1 + i].device, "ios:シミュ1");
    assert.equal(messages[1 + i].jpegBase64, `frame-${i}`);
    assert.equal(messages[1 + i].width, 480);
    assert.equal(messages[1 + i].height, 1040);
  }

  assert.equal(messages[4].device, "ios:シミュ2");
  assert.equal(messages[4].message, "ブリッジに接続できません");
});

/**
 * mock-monitor.mjs を spawn し、stdout を NdjsonParser → isMonitorEvent/toWebviewMessage に
 * 通して発生した webview メッセージを配列で返す(monitorPanel.ts が組む配線の縮小版)。
 * expectedCount 件受信した時点で stdin を EOF にして終了させる(mock-monitor.mjs は契約どおり
 * stdin EOF まで生存し続けるため)。想定件数に届かない不具合時に無限に待たないよう、
 * タイムアウトで強制終了するフォールバックも備える。
 */
function runMockMonitorThroughPipeline(mockArgs, expectedCount) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_MONITOR, ...mockArgs], {
      cwd: path.dirname(MOCK_MONITOR),
      stdio: ["pipe", "pipe", "pipe"],
    });

    const messages = [];
    const parser = new NdjsonParser(
      (value) => {
        if (!isMonitorEvent(value)) {
          return;
        }
        messages.push(toWebviewMessage(value));
        if (messages.length >= expectedCount) {
          proc.stdin.end();
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error("mock-monitor.mjs からの応答がタイムアウトしました"));
    }, 5000);

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", () => {
      clearTimeout(timer);
      parser.end();
      resolve(messages);
    });
  });
}

// ---- restartBatch(GPU 一括再起動)ジョブ ----

test("restartBatch: hasDeviceLifecycleJobFor が names 内のデバイスを検知する", () => {
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "restartBatch", names: ["A", "B"] });
  assert.equal(hasDeviceLifecycleJobFor(queue, "A"), true);
  assert.equal(hasDeviceLifecycleJobFor(queue, "B"), true);
  assert.equal(hasDeviceLifecycleJobFor(queue, "C"), false);
});

test("restartBatch: deviceLifecycleStatusFor は実行中(先頭)でも queued を返す", () => {
  // バッチ実行中の per-device 実状態は CLI の NDJSON イベントが deviceOpBusy で上書きする。
  // モデル側は「順番待ち」に留め、まだ触れていないデバイスをシャットダウン中と誤表示しない。
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "restartBatch", names: ["A", "B"] });
  assert.deepEqual(deviceLifecycleStatusFor(queue, "A"), { op: "down", status: "queued" });
  assert.deepEqual(deviceLifecycleStatusFor(queue, "B"), { op: "down", status: "queued" });
  assert.equal(deviceLifecycleStatusFor(queue, "C"), undefined);
});

test("restartBatch: monitor pause 不要(device down は従来どおり必要)", () => {
  assert.equal(deviceLifecycleJobNeedsMonitorPause({ kind: "restartBatch", names: ["A"] }), false);
  assert.equal(deviceLifecycleJobNeedsMonitorPause({ kind: "device", name: "A", op: "down" }), true);
  assert.equal(deviceLifecycleJobNeedsMonitorPause({ kind: "device", name: "A", op: "up" }), false);
});

test("restartBatch: bulkLifecycleOp に影響しない", () => {
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "restartBatch", names: ["A"] });
  assert.equal(bulkLifecycleOp(queue), null);
});

test("isMonitorFromWebviewMessage: devicesRestartGpu は非空 names 配列のみ受理する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: ["A"] }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: ["A", "B"] }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: [] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: ["A", ""] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: [1] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu" }), false);
});

test("isDevicesRestartEvent: 各 kind の受理と不正の拒否", () => {
  assert.equal(isDevicesRestartEvent({ kind: "log", message: "m" }), true);
  assert.equal(isDevicesRestartEvent({ kind: "deviceStopping", name: "A", platform: "android" }), true);
  assert.equal(isDevicesRestartEvent({ kind: "deviceStarting", name: "A", platform: "android" }), true);
  assert.equal(isDevicesRestartEvent({ kind: "deviceFinished", name: "A", platform: "android" }), true);
  assert.equal(isDevicesRestartEvent({ kind: "finished", ok: true }), true);
  assert.equal(isDevicesRestartEvent({ kind: "deviceStopping" }), false);
  assert.equal(isDevicesRestartEvent({ kind: "unknown" }), false);
  assert.equal(isDevicesRestartEvent(null), false);
});

// ---- devicesUp の restartNames 統合(未起動ブートと CPU 機再起動の同一キュー化) ----

test("isMonitorFromWebviewMessage: devicesUp は restartNames 省略/空/非空文字列配列を受理する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp", restartNames: [] }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp", restartNames: ["A", "B"] }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp", restartNames: ["A", ""] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp", restartNames: [1] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp", restartNames: "A" }), false);
});

test("isDevicesUpEvent: deviceStopping(--restart の down 開始)を受理する", () => {
  assert.equal(isDevicesUpEvent({ kind: "deviceStopping", name: "A", platform: "android" }), true);
  assert.equal(isDevicesUpEvent({ kind: "deviceStopping" }), false);
});

test("bulk up の restartNames を hasDeviceLifecycleJobFor が検知する(右クリック連打防止)", () => {
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "bulk", op: "up", restartNames: ["A"] });
  assert.equal(hasDeviceLifecycleJobFor(queue, "A"), true);
  assert.equal(hasDeviceLifecycleJobFor(queue, "B"), false);
});

test("bulk up の restartNames は実行中でも down/queued(再起動待機中表示)を返す", () => {
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "bulk", op: "up", restartNames: ["A"] });
  assert.deepEqual(deviceLifecycleStatusFor(queue, "A"), { op: "down", status: "queued" });
  assert.equal(deviceLifecycleStatusFor(queue, "B"), undefined);
});

// ---- デバイスの起動を中断(devicesUpCancel / removeQueuedBulkUpJob) ----

test("isMonitorFromWebviewMessage: devicesUpCancel を受理する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUpCancel" }), true);
});

test("removeQueuedBulkUpJob: キュー待ちの bulk up を除去し、実行中(先頭)は触らない", () => {
  let queue = createDeviceLifecycleQueueState();
  queue = enqueueDeviceLifecycleJob(queue, { kind: "device", name: "X", op: "down" });
  queue = enqueueDeviceLifecycleJob(queue, { kind: "bulk", op: "up", restartNames: ["A"] });
  const result = removeQueuedBulkUpJob(queue);
  assert.deepEqual(result.removed, { kind: "bulk", op: "up", restartNames: ["A"] });
  assert.equal(result.state.jobs.length, 1, "bulk up だけ除去される");

  // 実行中(running)の bulk up は除去しない(プロセス kill で止める領分)。
  let running = createDeviceLifecycleQueueState();
  running = enqueueDeviceLifecycleJob(running, { kind: "bulk", op: "up" });
  running = promoteDeviceLifecycleJobs(running).state;
  const noop = removeQueuedBulkUpJob(running);
  assert.equal(noop.removed, undefined);
  assert.equal(noop.state.running.length, 1);
});
