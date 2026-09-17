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
  addDevicesToRunProfile,
  buildRunProfileTemplate,
  bulkLifecycleOp,
  createDeviceLifecycleQueueState,
  finishDeviceLifecycleJob,
  deviceLifecycleJobNeedsMonitorPause,
  promoteDeviceLifecycleJobs,
  deviceLifecycleStatusFor,
  deviceOpMenuItem,
  enqueueDeviceLifecycleJob,
  filterMonitorDevices,
  deleteDeviceApiArgs,
  hasDeviceLifecycleJobFor,
  installSystemImageApiArgs,
  isCreateDeviceEvent,
  isDeleteDeviceEvent,
  isDeviceCatalogJson,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesRestartEvent,
  isDevicesUpEvent,
  isInstallSystemImageEvent,
  isInstalledDevicesJson,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  machineDeviceDetail,
  monitorControlLine,
  orderedDeviceEntry,
  parseAppProfileForForm,
  parseRunProfileForForm,
  removeDeviceFromRunProfile,
  removeQueuedBulkUpJob,
  RUNNING_DEVICES_PROFILE_VALUE,
  runProfileDeviceRefKey,
  toWebviewMessage,
  updateAppProfileInObject,
  updateRunProfileInObject,
  validateNewAppProfileName,
  validateNewDeviceName,
  validateNewProjectName,
  validateNewRunProfileName,
} from "../src/monitorModel";

// esbuild がこのテストを out-test/ にバンドルするため、import.meta.url はバンドル後の
// 場所を指す。npm test は常に vscode-fleetest/ を cwd として実行されるので、
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
  const value = { kind: "monitorError", message: "実行プロファイルが未設定です" };
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
      { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "booting", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(invalidState), false);

  // "unknown" は**誰も観測していない**の意味で正規の state(offline = 止まっている とは別物)。
  // 弾くとリモートのタイルが devices ごと落ちて画面から消える
  const unknownState = {
    kind: "monitorDevices",
    devices: [
      {
        id: "ios:M1Max/シミュ1", name: "シミュ1", platform: "ios", state: "unknown", detail: "",
        machine: "M1Max",
      },
    ],
  };
  assert.equal(isMonitorEvent(unknownState), true);
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

test("isMonitorEvent: monitorDevices の frozen は欠落・非boolean値を false に正規化する(旧 CLI 互換)", () => {
  for (const raw of [undefined, null, "true", 1]) {
    const device = { id: "d1", name: "d1", platform: "ios", state: "connected", detail: "" };
    if (raw !== undefined) {
      device.frozen = raw;
    }
    const value = { kind: "monitorDevices", devices: [device] };
    assert.equal(isMonitorEvent(value), true);
    assert.equal(value.devices[0].frozen, false, `frozen=${JSON.stringify(raw)}`);
  }
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

test("isMonitorEvent: monitorDevices の registered は欠落・非boolean値を true に正規化する(旧CLI互換)", () => {
  const missing = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "" }],
  };
  assert.equal(isMonitorEvent(missing), true);
  assert.equal(missing.devices[0].registered, true);

  const nullValue = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", registered: null }],
  };
  assert.equal(isMonitorEvent(nullValue), true);
  assert.equal(nullValue.devices[0].registered, true);

  const invalidType = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", registered: "false" }],
  };
  assert.equal(isMonitorEvent(invalidType), true);
  assert.equal(invalidType.devices[0].registered, true);
});

test("isMonitorEvent: monitorDevices の registered は true/false をそのまま保持する", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "d1", name: "d1", platform: "ios", state: "connected", detail: "", registered: true },
      { id: "d2", name: "d2", platform: "android", state: "connected", detail: "", registered: false },
    ],
  };
  assert.equal(isMonitorEvent(value), true);
  assert.equal(value.devices[0].registered, true);
  assert.equal(value.devices[1].registered, false);
});

// bridgeRunning は registered と違い「欠落は true」ではなく「欠落は undefined(不明)」に
// 正規化する —— false に丸めると、Android 実機のブリッジが生きているのに観測できなかった
// 回にタイルの絵が消える(ApiMonitorCommand.swift の bridgeRunningVerdict と同じ規律)。
test("isMonitorEvent: monitorDevices の bridgeRunning は欠落・null・非boolean値を undefined に正規化する(false に倒さない)", () => {
  const missing = {
    kind: "monitorDevices",
    devices: [{ id: "d1", name: "d1", platform: "android", state: "connected", detail: "" }],
  };
  assert.equal(isMonitorEvent(missing), true);
  assert.equal(missing.devices[0].bridgeRunning, undefined);

  const nullValue = {
    kind: "monitorDevices",
    devices: [
      { id: "d1", name: "d1", platform: "android", state: "connected", detail: "", bridgeRunning: null },
    ],
  };
  assert.equal(isMonitorEvent(nullValue), true);
  assert.equal(nullValue.devices[0].bridgeRunning, undefined);

  const invalidType = {
    kind: "monitorDevices",
    devices: [
      { id: "d1", name: "d1", platform: "android", state: "connected", detail: "", bridgeRunning: "false" },
    ],
  };
  assert.equal(isMonitorEvent(invalidType), true);
  assert.equal(invalidType.devices[0].bridgeRunning, undefined);
});

test("isMonitorEvent: monitorDevices の bridgeRunning は true/false を区別して保持する(3値)", () => {
  const value = {
    kind: "monitorDevices",
    devices: [
      { id: "d1", name: "d1", platform: "android", state: "connected", detail: "", bridgeRunning: true },
      { id: "d2", name: "d2", platform: "android", state: "connected", detail: "", bridgeRunning: false },
      { id: "d3", name: "d3", platform: "ios", state: "connected", detail: "" },
    ],
  };
  assert.equal(isMonitorEvent(value), true);
  assert.equal(value.devices[0].bridgeRunning, true);
  assert.equal(value.devices[1].bridgeRunning, false, "未起動(false)は不明(undefined)に潰さない");
  assert.equal(value.devices[2].bridgeRunning, undefined);
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

test("isMonitorFromWebviewMessage: copyText は空でない text だけ通す", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "copyText", text: "エラー全文" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "copyText", text: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "copyText" }), false);
});

test("isMonitorFromWebviewMessage: ready/devicesUp/devicesDown/restartMonitor/runTests/cancelTests を true と判定する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "ready" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesUp" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesDown" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "restartMonitor" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "runTests" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "cancelTests" }), true);
});

test("isMonitorFromWebviewMessage: batchCreateDevices は names を検証する(空・99超・空文字は false)", () => {
  const base = {
    type: "batchCreateDevices",
    platform: "ios",
    names: ["dev00", "dev01"],
    model: "iPhone 17 Pro",
    os: "iOS 27.0",
    overwriteNames: [],
    source: { kind: "local" },
  };
  assert.equal(isMonitorFromWebviewMessage(base), true);
  assert.equal(isMonitorFromWebviewMessage({ ...base, names: [] }), false, "0台は受けない");
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, names: Array.from({ length: 100 }, (_v, i) => `d${i}`) }),
    false,
    "上限 99 を超えたら受けない(UI の max と同じ)",
  );
  assert.equal(isMonitorFromWebviewMessage({ ...base, names: ["dev00", ""] }), false, "空文字の名前は受けない");
  assert.equal(isMonitorFromWebviewMessage({ ...base, overwriteNames: [""] }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, platform: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, model: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, os: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, source: { kind: "unknown" } }), false);
});

test("isMonitorFromWebviewMessage: batchCreateDevices の installSystemImage は省略可・型が合えば true", () => {
  const base = {
    type: "batchCreateDevices",
    machine: "M1",
    platform: "android",
    names: ["dev00"],
    model: "pixel_9",
    os: "system-images;android-36;google_apis;arm64-v8a",
    overwriteNames: [],
    source: { kind: "local" },
  };
  assert.equal(isMonitorFromWebviewMessage(base), true, "省略は従来どおり true");
  assert.equal(
    isMonitorFromWebviewMessage({
      ...base,
      installSystemImage: { package: "system-images;android-36;google_apis;arm64-v8a", sizeBytes: 1900000000, license: "android-sdk-arm-dbt-license" },
    }),
    true,
  );
  // sizeBytes/license は null を許容する(不明を断定しない)
  assert.equal(
    isMonitorFromWebviewMessage({
      ...base,
      installSystemImage: { package: "pkg", sizeBytes: null, license: null },
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, installSystemImage: { package: "", sizeBytes: null, license: null } }),
    false,
    "package は空文字を受けない",
  );
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, installSystemImage: { package: "pkg", sizeBytes: "1", license: null } }),
    false,
    "sizeBytes は number|null のみ",
  );
});

test("isMonitorFromWebviewMessage: createDevice の installSystemImage は省略可・型が合えば true", () => {
  const base = {
    type: "createDevice",
    machine: "M1",
    platform: "android",
    name: "dev00",
    model: "pixel_9",
    os: "system-images;android-36;google_apis;arm64-v8a",
    register: true,
    source: { kind: "local" },
  };
  assert.equal(isMonitorFromWebviewMessage(base), true, "省略は従来どおり true");
  assert.equal(
    isMonitorFromWebviewMessage({
      ...base,
      installSystemImage: { package: "system-images;android-36;google_apis;arm64-v8a", sizeBytes: 1900000000, license: "android-sdk-arm-dbt-license" },
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, installSystemImage: { package: "pkg", sizeBytes: null, license: null } }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, installSystemImage: { package: "pkg", sizeBytes: null, license: 1 } }),
    false,
    "license は string|null のみ",
  );
  assert.equal(
    isMonitorFromWebviewMessage({ ...base, installSystemImage: {} }),
    false,
    "package 欠落は不正",
  );
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

test("isMonitorFromWebviewMessage: setTileAutoFit は受理しない(自動フィットは無い)", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "setTileAutoFit", value: true }), false);
});

test("isMonitorFromWebviewMessage: setRemoteConfig は hosts[](machine/host/dir)なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "setRemoteConfig",
      hosts: [{ machine: "mac-01", host: "user@mac-01", dir: "" }],
    }),
    true,
  );
  // hosts 空配列も正常値
  assert.equal(
    isMonitorFromWebviewMessage({ type: "setRemoteConfig", hosts: [] }),
    true,
  );
});

test("isMonitorFromWebviewMessage: setRemoteConfig は hosts 要素の型不正・hosts 欠落なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "setRemoteConfig" }), false);
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "setRemoteConfig",
      hosts: [{ machine: "mac-01", host: 123, dir: "" }],
    }),
    false,
  );
  // マシン名のキーは "machine"。旧キー "name" だけの行は通さない(settingsTab.js は machine で送る)
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "setRemoteConfig",
      hosts: [{ name: "mac-01", host: "user@mac-01", dir: "" }],
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "setRemoteConfig", hosts: "not-an-array" }),
    false,
  );
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

test("isMonitorFromWebviewMessage: deviceOp の udid/serial/registered は省略可・型が合えば true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "down", udid: "ABCD-1234", registered: false }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "deviceOp", name: "エミュ1", op: "down", serial: "emulator-5554", registered: false }),
    true,
  );
});

test("isMonitorFromWebviewMessage: deviceOp の udid/serial/registered は型が不正なら false", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "down", udid: 1 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceOp", name: "エミュ1", op: "down", serial: 1 }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "deviceOp", name: "シミュ1", op: "down", registered: "false" }),
    false,
  );
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

test("isDeviceOpEvent: wipe-device の wipeStatus は既知の phase だけ true", () => {
  for (const phase of ["stopping", "rebooting", "done", "failed"]) {
    assert.equal(isDeviceOpEvent({ kind: "wipeStatus", phase }), true);
  }
  assert.equal(isDeviceOpEvent({ kind: "wipeStatus" }), false);
  assert.equal(isDeviceOpEvent({ kind: "wipeStatus", phase: "erasing" }), false);
  assert.equal(isDeviceOpEvent({ kind: "wipeStatus", phase: 1 }), false);
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

test("deviceOpMenuItem: busy.op='wipe' は「Wipe Data 実行中...」(タイルからの起動/停止を塞ぐ)", () => {
  assert.deepEqual(deviceOpMenuItem("connected", { op: "wipe", status: "running" }), {
    label: "Wipe Data 実行中...",
    op: "wipe",
    disabled: true,
  });
  assert.deepEqual(deviceOpMenuItem("offline", { op: "wipe", status: "running" }), {
    label: "Wipe Data 実行中...",
    op: "wipe",
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

// 同時実行の上限は**機械ごと**。「2台同時でホスト CPU がほぼ飽和する」という実測はその機械の
// CPU の話で、別の機械の起動を止める理由が無い。全機で共有していたため、M2Ultra の2台を
// 起こしている間 M1Max の台が「起動待機」で止まった(2026-08-17 の実害)。
test("DeviceLifecycleQueue: 同時実行の上限は機械ごとに数える", () => {
  let state = createDeviceLifecycleQueueState();
  for (const job of [
    { kind: "device", name: "A", op: "up", machine: "M2Ultra" },
    { kind: "device", name: "B", op: "up", machine: "M2Ultra" },
    { kind: "device", name: "C", op: "up", machine: "M1Max" },
    { kind: "device", name: "D", op: "up", machine: "M1Max" },
    { kind: "device", name: "E", op: "up", machine: "M2Ultra" },
  ]) {
    state = enqueueDeviceLifecycleJob(state, job);
  }
  const result = promoteDeviceLifecycleJobs(state);
  assert.deepEqual(
    result.started.map((j) => `${j.machine}/${j.name}`),
    ["M2Ultra/A", "M2Ultra/B", "M1Max/C", "M1Max/D"],
    "機械ごとに2台ずつ。3台目(M2Ultra/E)だけが待つ",
  );
});

test("DeviceLifecycleQueue: 先頭が詰まっていても空いている機械のジョブは進む", () => {
  let state = createDeviceLifecycleQueueState();
  for (const job of [
    { kind: "device", name: "A", op: "up", machine: "M2Ultra" },
    { kind: "device", name: "B", op: "up", machine: "M2Ultra" },
    { kind: "device", name: "C", op: "up", machine: "M2Ultra" }, // ここで M2Ultra は満杯
    { kind: "device", name: "D", op: "up", machine: "M1Max" },
  ]) {
    state = enqueueDeviceLifecycleJob(state, job);
  }
  const started = promoteDeviceLifecycleJobs(state).started.map((j) => `${j.machine}/${j.name}`);
  assert.ok(started.includes("M1Max/D"),
    "FIFO を機械をまたいで守る意味は無い(それが『起動待機』の正体)");
  assert.ok(!started.includes("M2Ultra/C"), "満杯の機械の3台目は待つ");
});

test("DeviceLifecycleQueue: 手元だけの構成では従来どおり2台で頭打ち", () => {
  let state = createDeviceLifecycleQueueState();
  for (const name of ["A", "B", "C"]) {
    state = enqueueDeviceLifecycleJob(state, { kind: "device", name, op: "up" });
  }
  assert.deepEqual(
    promoteDeviceLifecycleJobs(state).started.map((j) => j.name), ["A", "B"]);
});

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

test("deviceLifecycleJobNeedsMonitorPause: device wipe は true(中で停止するため down と同じ)", () => {
  assert.equal(
    deviceLifecycleJobNeedsMonitorPause({ kind: "device", name: "シミュ1", op: "wipe" }),
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

// ---- filterMonitorDevices(「起動中のデバイス」表示フィルタ) ----

const SIM1 = { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "" };
const SIM2 = { id: "ios:シミュ2", name: "シミュ2", platform: "ios", state: "booted", detail: "" };
const SIM3_OFFLINE = { id: "ios:シミュ3", name: "シミュ3", platform: "ios", state: "offline", detail: "" };
const EMU1 = { id: "android:エミュ1", name: "エミュ1", platform: "android", state: "connected", detail: "" };
const IPHONE_PHYSICAL_NO_BRIDGE = {
  id: "ios:実機1", name: "実機1", platform: "ios", state: "booted", detail: "", kind: "physical",
};

test("filterMonitorDevices: 'running' は unknown(誰も観測していない)を含めない", () => {
  const devices = [
    { id: "ios:A", name: "A", platform: "ios", state: "connected", detail: "", kind: "virtual" },
    { id: "ios:M1Max/A", name: "A", platform: "ios", state: "unknown", detail: "", kind: "virtual",
      machine: "M1Max" },
  ];
  assert.deepEqual(filterMonitorDevices(devices, "running").map((d) => d.id), ["ios:A"]);
});

test("filterMonitorDevices: filter='all' は素通し(同一内容・順序)", () => {
  const devices = [SIM1, SIM3_OFFLINE, EMU1];
  assert.deepEqual(filterMonitorDevices(devices, "all"), devices);
});

test("filterMonitorDevices: filter='running' は offline を除外し順序を保つ", () => {
  assert.deepEqual(filterMonitorDevices([SIM1, SIM3_OFFLINE, SIM2, EMU1], "running"), [SIM1, SIM2, EMU1]);
});

test("filterMonitorDevices: booted(ブート完了待ち)は起動中として残す", () => {
  assert.deepEqual(filterMonitorDevices([SIM2], "running"), [SIM2]);
});

test("filterMonitorDevices: 全て offline なら空配列", () => {
  assert.deepEqual(filterMonitorDevices([SIM3_OFFLINE], "running"), []);
  assert.deepEqual(filterMonitorDevices([], "running"), []);
});

// iOS 実機の booted = 端末は繋がっているがブリッジが1本も無い。**2026-08-26 に方針変更**:
// api monitor が接続中の実機を合成するようになったので、繋がっている端末を「起動中のデバイス」から
// 隠すほうが実態と食い違う(ブリッジはタイルのメニューから起こせる)。
test("filterMonitorDevices: booted の iOS 実機(ブリッジ不在)も起動中に出す", () => {
  assert.deepEqual(
    filterMonitorDevices([SIM1, IPHONE_PHYSICAL_NO_BRIDGE, EMU1], "running"),
    [SIM1, IPHONE_PHYSICAL_NO_BRIDGE, EMU1],
    "繋がっている実機を隠さない(タイル側が『ブリッジ未起動』として出す)",
  );
  assert.deepEqual(filterMonitorDevices([IPHONE_PHYSICAL_NO_BRIDGE], "all"), [IPHONE_PHYSICAL_NO_BRIDGE]);
});

test("filterMonitorDevices: connected の iOS 実機・booted の Android 実機は残す", () => {
  const iosConnected = { ...IPHONE_PHYSICAL_NO_BRIDGE, state: "connected" };
  const androidBooting = {
    id: "android:実機A", name: "実機A", platform: "android", state: "booted", detail: "", kind: "physical",
  };
  assert.deepEqual(filterMonitorDevices([iosConnected, androidBooting], "running"), [iosConnected, androidBooting]);
});

// 未登録(どの実行プロファイルにも記載が無い合成デバイス。determineStates(includeUnregistered:) 参照)
const SIM_UNREGISTERED = { ...SIM1, id: "ios:野良シム", name: "野良シム", registered: false };

// **落とさない**。以前は除外していたが、実行プロファイルが2つ以上ある案件では
// `--profile` 無しの `api monitor` が対象を1つに決められず全台を registered:false で出すため、
// 「(プロファイルなし)で1台も出ない」になっていた(実害 2026-08-28)。
test("filterMonitorDevices: filter='all' は registered=false も落とさない", () => {
  assert.deepEqual(
    filterMonitorDevices([SIM1, SIM_UNREGISTERED, EMU1], "all"),
    [SIM1, SIM_UNREGISTERED, EMU1],
  );
});

test("filterMonitorDevices: 全台が未登録でも 'all' は空にならない(縮退した監視の実データ)", () => {
  const devices = [SIM_UNREGISTERED, { ...SIM_UNREGISTERED, id: "ios:野良シム2" }];
  assert.equal(filterMonitorDevices(devices, "all").length, 2);
});

test("filterMonitorDevices: filter='running' は registered=false も素通しする(未登録は定義上起動中)", () => {
  assert.deepEqual(
    filterMonitorDevices([SIM1, SIM_UNREGISTERED, EMU1], "running"),
    [SIM1, SIM_UNREGISTERED, EMU1],
  );
});

test("RUNNING_DEVICES_PROFILE_VALUE: webview 側の複製定数(deviceTiles.js)と一致する", () => {
  assert.equal(RUNNING_DEVICES_PROFILE_VALUE, "@running");
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

test("validateNewRunProfileName: '@' で始まる場合はエラー(予約値との衝突防止)", () => {
  assert.notEqual(validateNewRunProfileName("@running", []), null);
  assert.notEqual(validateNewRunProfileName("@other", []), null);
});

test("validateNewRunProfileName: 既存名と重複する場合はエラー", () => {
  assert.notEqual(validateNewRunProfileName("ios", ["ios", "android"]), null);
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

// ---- validateNewProjectName(新規/コピー先/リネーム後のテストプロジェクト名検証) ----

test("validateNewProjectName: 妥当な名前は null(問題なし)", () => {
  assert.equal(validateNewProjectName("sampleapp", []), null);
  assert.equal(validateNewProjectName("My-App_1", ["sampleapp"]), null);
  assert.equal(validateNewProjectName("_hidden", []), null);
});

test("validateNewProjectName: 空文字はエラー", () => {
  assert.notEqual(validateNewProjectName("", []), null);
});

test("validateNewProjectName: 前後に空白を含む(trim済みでない)場合はエラー", () => {
  assert.notEqual(validateNewProjectName(" sampleapp", []), null);
  assert.notEqual(validateNewProjectName("sampleapp ", []), null);
});

test("validateNewProjectName: 日本語を含む場合はエラー", () => {
  assert.notEqual(validateNewProjectName("サンプル", []), null);
});

test("validateNewProjectName: '/' を含む場合はエラー", () => {
  assert.notEqual(validateNewProjectName("a/b", []), null);
});

test("validateNewProjectName: '-' で始まる場合はエラー(SPM ターゲット名の制約)", () => {
  assert.notEqual(validateNewProjectName("-hidden", []), null);
});

test("validateNewProjectName: 既存名と重複する場合はエラー", () => {
  assert.notEqual(validateNewProjectName("sampleapp", ["sampleapp", "otherapp"]), null);
});

// ---- buildRunProfileTemplate(新規実行プロファイルのテンプレートJSON生成) ----

test("buildRunProfileTemplate: 候補ありなら先頭のappを使い、devicesは空配列", () => {
  const json = buildRunProfileTemplate(["sampleapp", "otherapp"]);
  assert.ok(json.endsWith("\n"));
  const parsed = JSON.parse(json);
  assert.deepEqual(parsed, {
    app: "sampleapp",
    devices: [],
    heal: true,
    textVisualCheck: true,
    ocrTextVisualCheck: true,
    screenLooksLike: true,
    iosInappEngine: true,
    updateWebView: true,
    wipeDataOnBloat: true,
  });
});

test("buildRunProfileTemplate: 候補が無ければ app は空文字", () => {
  const json = buildRunProfileTemplate([]);
  const parsed = JSON.parse(json);
  assert.deepEqual(parsed, {
    app: "",
    devices: [],
    heal: true,
    textVisualCheck: true,
    ocrTextVisualCheck: true,
    screenLooksLike: true,
    iosInappEngine: true,
    updateWebView: true,
    wipeDataOnBloat: true,
  });
});

// ---- isMonitorFromWebviewMessage: deviceCatalogRequest/createDevice ----

test("isMonitorFromWebviewMessage: deviceCatalogRequest/installedDevicesRequest は source が local/remote(machine非空)なら true", () => {
  for (const type of ["deviceCatalogRequest", "installedDevicesRequest"]) {
    assert.equal(isMonitorFromWebviewMessage({ type, source: { kind: "local" } }), true);
    assert.equal(isMonitorFromWebviewMessage({ type, source: { kind: "remote", machine: "M1Max" } }), true);
  }
});

test("isMonitorFromWebviewMessage: deviceCatalogRequest/installedDevicesRequest は source 欠落/不正なら false", () => {
  for (const type of ["deviceCatalogRequest", "installedDevicesRequest"]) {
    assert.equal(isMonitorFromWebviewMessage({ type }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, source: { kind: "remote", machine: "" } }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, source: { kind: "remote" } }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, source: { kind: "bogus" } }), false);
    assert.equal(isMonitorFromWebviewMessage({ type, source: null }), false);
  }
});

// ---- isMonitorFromWebviewMessage: createDevice(machine プロファイル統合で machine フィールドは廃止) ----

test("isMonitorFromWebviewMessage: createDevice は全フィールドが非空文字列(platformはios/android)+registerがboolean+sourceが妥当なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "createDevice",
      platform: "ios",
      name: "シミュ1",
      model: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      os: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      register: true,
      source: { kind: "local" },
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "createDevice",
      platform: "android",
      name: "エミュ1",
      model: "pixel_9_pro",
      os: "system-images;android-37;google_apis;arm64-v8a",
      register: false,
      source: { kind: "remote", machine: "M1Max" },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: createDevice はフィールド欠落/空文字/不正platform/register非boolean/source不正なら false", () => {
  const base = {
    type: "createDevice",
    platform: "ios",
    name: "n",
    model: "m",
    os: "o",
    register: true,
    source: { kind: "local" },
  };
  assert.equal(isMonitorFromWebviewMessage({ ...base, name: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, model: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, os: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, platform: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, register: "true" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, register: undefined }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, source: { kind: "remote", machine: "" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, source: { kind: "bogus" } }), false);
  const { register, ...missingRegister } = base;
  assert.equal(isMonitorFromWebviewMessage(missingRegister), false);
  const { source, ...missingSource } = base;
  assert.equal(isMonitorFromWebviewMessage(missingSource), false);
});

test("isMonitorFromWebviewMessage: devicePickDeviceDelete は platform(ios/android)+identifier/name 非空文字列+source 妥当なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "devicePickDeviceDelete",
      platform: "ios",
      identifier: "ABCDEFGH-1234",
      name: "シミュ1",
      source: { kind: "local" },
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "devicePickDeviceDelete",
      platform: "android",
      identifier: "Pixel_9_API_37",
      name: "エミュ1",
      source: { kind: "remote", machine: "M1Max" },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: devicePickDeviceDelete はフィールド欠落/空文字/不正platform/source不正なら false", () => {
  const base = {
    type: "devicePickDeviceDelete",
    platform: "ios",
    identifier: "UDID-1",
    name: "n",
    source: { kind: "local" },
  };
  assert.equal(isMonitorFromWebviewMessage({ ...base, platform: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, identifier: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, name: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, source: { kind: "remote", machine: "" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ ...base, source: { kind: "bogus" } }), false);
  const { identifier, ...missingIdentifier } = base;
  assert.equal(isMonitorFromWebviewMessage(missingIdentifier), false);
});

test("isMonitorFromWebviewMessage: runProfileDeviceRemove は devices 非空配列(各要素 platform+name 非空文字列)なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: [{ platform: "ios", name: "シミュ1" }] }),
    true,
  );
  // machine は省略可(=手元)。指定があれば非空文字列。
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDeviceRemove",
      devices: [{ platform: "ios", name: "シミュ1", machine: "M1Max" }],
    }),
    true,
  );
  // 複数選択の一括除去。同名が別ホストに並ぶのは通常。
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDeviceRemove",
      devices: [{ platform: "ios", name: "シミュ1" }, { platform: "ios", name: "シミュ1", machine: "M1Max" }],
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: runProfileDeviceWipe は name/platform/identifier が揃っていれば true", () => {
  const ios = { name: "シミュ1", platform: "ios", identifier: "UDID-1" };
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [ios] }), true);
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDeviceWipe",
      devices: [ios, { name: "エミュ1", platform: "android", identifier: "Pixel_8", machine: "M1Max" }],
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: runProfileDeviceWipe は識別子を欠くと false(名前では撃たない)", () => {
  const ok = { name: "シミュ1", platform: "ios", identifier: "UDID-1" };
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe" }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [{ name: "シミュ1" }] }),
    false, // 名前だけでは撃たない(CLI は識別子でしか受け付けない)
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [{ ...ok, identifier: "" }] }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [{ ...ok, platform: "web" }] }),
    false,
  );
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [{ ...ok, name: "" }] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: ["シミュ1"] }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceWipe", devices: [{ ...ok, machine: "" }] }),
    false, // machine は指定するなら非空("" は「手元」ではなく不正)
  );
});

test("isMonitorFromWebviewMessage: runProfileDeviceRemove は devices 空配列・欠落・要素不正なら false", () => {
  const devices = [{ platform: "ios", name: "シミュ1" }];
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: [] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: [{ platform: "ios", name: "" }] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: [{ platform: "windows", name: "n" }] }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: [{ platform: "ios", name: "OK", machine: "" }] }),
    false, // machine は指定するなら非空("" は「手元」ではなく不正)
  );
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: ["シミュ1"] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove" }), false);
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDeviceRemove", devices: { platform: "ios", name: "シミュ1" } }),
    false, // devices は配列必須(単体オブジェクトは不可)
  );
  assert.notEqual(devices.length, 0); // devices は上のケースで再利用するためのフィクスチャ
});

// ---- isMonitorFromWebviewMessage: runProfileDevicesSync(「+既存から選択」モーダルの OK) ----

const VALID_SYNC_ADD_IOS_ENTRY = {
  platform: "ios",
  name: "iPhone 17 Pro",
  osVersion: "iOS 27.0",
  udid: "1C86FAKE-0000-0000-0000-000000000000",
  model: "iPhone 17 Pro",
};

const VALID_SYNC_ADD_ANDROID_ENTRY = {
  platform: "android",
  name: "Pixel 9(Android 16)",
  avd: "Pixel_9",
};

const LOCAL_SOURCE = { kind: "local" };

test("isMonitorFromWebviewMessage: runProfileDevicesSync は profile 非空・add 非空なら true", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [VALID_SYNC_ADD_IOS_ENTRY, VALID_SYNC_ADD_ANDROID_ENTRY],
      source: LOCAL_SOURCE,
    }),
    true,
  );
  // オプショナルフィールド(osVersion/udid/avd/model)は省略可。
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [{ platform: "ios", name: "n" }],
      source: LOCAL_SOURCE,
    }),
    true,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
      source: { kind: "remote", machine: "M1Max" },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: runProfileDevicesSync は source 欠落/不正なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
      source: { kind: "remote", machine: "" },
    }),
    false,
  );
});

test("isMonitorFromWebviewMessage: runProfileDevicesSync は profile 空文字なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "",
      add: [VALID_SYNC_ADD_IOS_ENTRY],
      source: LOCAL_SOURCE,
    }),
    false,
  );
});

test("isMonitorFromWebviewMessage: runProfileDevicesSync は add が空/欠落/配列でなければ false(除去はこのメッセージの役目ではない)", () => {
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDevicesSync", profile: "ios", add: [], source: LOCAL_SOURCE }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({ type: "runProfileDevicesSync", profile: "ios", source: LOCAL_SOURCE }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync", profile: "ios", add: "not-array", source: LOCAL_SOURCE,
    }),
    false,
  );
});

test("isMonitorFromWebviewMessage: runProfileDevicesSync は add 要素が不正なら false", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [{ platform: "ios", name: "" }],
      source: LOCAL_SOURCE,
    }),
    false, // name 空文字
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [{ platform: "windows", name: "n" }],
      source: LOCAL_SOURCE,
    }),
    false, // 不正 platform
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "runProfileDevicesSync",
      profile: "ios",
      add: [{ platform: "ios", name: "n", udid: 123 }],
      source: LOCAL_SOURCE,
    }),
    false, // オプショナルフィールドの型不正
  );
});

// ---- isMonitorFromWebviewMessage: 実行プロファイル設定フォーム(runProfileLoad/runProfileSave) ----

const VALID_RUN_PROFILE_SAVE = {
  type: "runProfileSave",
  profile: "run1",
  fields: {
    app: "sampleapp",
    devices: [
      { platform: "ios", name: "シミュ1", enabled: true },
      { platform: "android", name: "エミュ1", enabled: true, machine: "M1Max" },
    ],
    heal: false,
    textVisualCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextVisualCheck: true,
    iosInappEngine: true,
    iosFastInput: false,
    iosPreActionWarmup: true,
    homeOnStart: true,
    enableAnimations: false,
    reportDir: "reports",
    updateWebView: true,
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "1",
    recoverCpuFallbackToGpu: false,
    locale: "ja_JP",
    record: false,
    recordFailuresOnly: false,
    recordBitrateKbps: "",
    recordFullResolution: false,
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

test("isMonitorFromWebviewMessage: runProfileSave は profile 非空・fields21項目の型が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage(VALID_RUN_PROFILE_SAVE), true);
  // devices は空配列も(型としては)許容する — 「1件以上」の検証はクライアント側の別ロジックが担う。
  assert.equal(
    isMonitorFromWebviewMessage({ ...VALID_RUN_PROFILE_SAVE, fields: { ...VALID_RUN_PROFILE_SAVE.fields, devices: [] } }),
    true,
  );
  // app/reportDir/wipeDataThresholdGB/locale は空文字も(型としては)許容する。
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: {
        app: "",
        devices: [],
        heal: true,
        textVisualCheck: false,
        screenLooksLike: false,
        containerInference: false,
        ocrTextVisualCheck: false,
        iosInappEngine: false,
        iosFastInput: true,
        iosPreActionWarmup: false,
        homeOnStart: true,
        enableAnimations: true,
        reportDir: "",
        updateWebView: true,
        wipeDataOnBloat: false,
        wipeDataThresholdGB: "",
        recoverCpuFallbackToGpu: true,
        locale: "",
        record: true,
        recordFailuresOnly: true,
        recordBitrateKbps: "",
        recordFullResolution: true,
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
      fields: {
        ...VALID_RUN_PROFILE_SAVE.fields,
        devices: [{ platform: "ios", name: "シミュ1", enabled: true }, { platform: "ios", name: 1, enabled: true }],
      }, // name が非文字列
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: {
        ...VALID_RUN_PROFILE_SAVE.fields,
        devices: [{ platform: "windows", name: "n", enabled: true }],
      }, // platform が ios/android でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: {
        ...VALID_RUN_PROFILE_SAVE.fields,
        devices: [{ platform: "ios", name: "n" }],
      }, // enabled 欠落
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
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, textVisualCheck: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, screenLooksLike: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, containerInference: "true" }, // boolean でない
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
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, iosFastInput: "true" }, // boolean でない
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
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, recordFailuresOnly: "true" }, // boolean でない
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, recordBitrateKbps: 1500 }, // number(string でない)
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_RUN_PROFILE_SAVE,
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, recordFullResolution: "true" }, // boolean でない
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
// common は自動インストール(autoInstall。"" は廃止済みで "true"/"false" の2値のみ)のみ(表示名は
// 継承しないため common には無い)、ios/android は表示名・アプリID・パッケージパスの3項目
// (autoInstall は common に一本化されたため持たない。2026-07-11 指示)を持つ(monitorModel.ts の
// AppProfileCommonFields/AppProfilePlatformFields と同じ形)。

const APP_PROFILE_COMMON_FIELDS = {
  autoInstall: "true",
};

const APP_PROFILE_PLATFORM_FIELDS = {
  appName: "サンプル",
  app: "com.example.sample",
  appPath: "path/to.app",
};

// ios だけ実機に配るパッケージ(appPathPhysical)を持つ。
const APP_PROFILE_IOS_FIELDS = {
  ...APP_PROFILE_PLATFORM_FIELDS,
  appPathPhysical: "path/to-device.app",
};

const VALID_APP_PROFILE_SAVE = {
  type: "appProfileSave",
  profile: "sampleapp",
  fields: {
    common: APP_PROFILE_COMMON_FIELDS,
    ios: APP_PROFILE_IOS_FIELDS,
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

test("isMonitorFromWebviewMessage: appProfileSave は profile 非空・fields(common=自動インストールのみ、ios/android=3項目)の型が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage(VALID_APP_PROFILE_SAVE), true);
  // 各フィールドは空文字も(型としては)許容する。common の autoInstall は "true"/"false" の
  // 2値のみ("" は廃止)。
  const emptyCommon = { autoInstall: "false" };
  const emptyPlatform = { appName: "", app: "", appPath: "" };
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { common: emptyCommon, ios: { ...emptyPlatform, appPathPhysical: "" }, android: emptyPlatform },
    }),
    true,
  );
});

test("isMonitorFromWebviewMessage: appProfileSave の ios は appPathPhysical(実機に配るパッケージ)が必須・android は持たない", () => {
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, ios: APP_PROFILE_PLATFORM_FIELDS }, // appPathPhysical 欠落
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, ios: { ...APP_PROFILE_IOS_FIELDS, appPathPhysical: 1 } },
    }),
    false,
  );
  // android は欄が無いので、余分に付いていても検証は通す(未知キーとして無視される)。
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, android: APP_PROFILE_IOS_FIELDS },
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
      fields: { ...VALID_APP_PROFILE_SAVE.fields, ios: { ...APP_PROFILE_PLATFORM_FIELDS, appName: 1 } }, // appName 非文字列
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: { autoInstall: "" } }, // "" は廃止済みで不正
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: { autoInstall: "maybe" } }, // 2値以外
    }),
    false,
  );
  assert.equal(
    isMonitorFromWebviewMessage({
      ...VALID_APP_PROFILE_SAVE,
      fields: { ...VALID_APP_PROFILE_SAVE.fields, common: {} }, // autoInstall 欠落
    }),
    false,
  );
  const { android, ...missingAndroid } = VALID_APP_PROFILE_SAVE.fields;
  assert.equal(isMonitorFromWebviewMessage({ ...VALID_APP_PROFILE_SAVE, fields: missingAndroid }), false);
  const { fields: appFields, ...missingAppFields } = VALID_APP_PROFILE_SAVE;
  assert.equal(isMonitorFromWebviewMessage(missingAppFields), false);
});

// ---- machineDeviceDetail ----

test("machineDeviceDetail: iOS は Model / OS Version / UDID(シミュレータ・実機とも)", () => {
  assert.equal(
    machineDeviceDetail({ name: "シミュ1", platform: "ios", model: "iPhone 17 Pro", osVersion: "iOS 27.0", udid: "U0" }),
    "iPhone 17 Pro / iOS 27.0 / U0",
  );
  assert.equal(
    machineDeviceDetail({ name: "実機", platform: "ios", kind: "physical", model: "iPhone 17 Pro", osVersion: "iOS 18.2", udid: "00008110-001" }),
    "iPhone 17 Pro / iOS 18.2 / 00008110-001",
  );
});

test("machineDeviceDetail: 欠けた要素は飛ばして連結する(接頭辞を足さない)", () => {
  assert.equal(machineDeviceDetail({ name: "s", platform: "ios", osVersion: "iOS 27.0" }), "iOS 27.0");
  assert.equal(machineDeviceDetail({ name: "s", platform: "ios", model: "iPhone 17 Pro", udid: "U" }), "iPhone 17 Pro / U");
  assert.equal(machineDeviceDetail({ name: "s", platform: "ios", udid: "U" }), "U");
});

test("machineDeviceDetail: iOS は全部無ければ 'iOS'", () => {
  assert.equal(machineDeviceDetail({ name: "シミュ1", platform: "ios" }), "iOS");
});

test("machineDeviceDetail: Android 実機は Model / OS Version / Serial", () => {
  assert.equal(
    machineDeviceDetail({ name: "実機", platform: "android", kind: "physical", model: "Pixel 8", osVersion: "Android 15", serial: "14141JEC204922" }),
    "Pixel 8 / Android 15 / 14141JEC204922",
  );
  assert.equal(
    machineDeviceDetail({ name: "実機", platform: "android", kind: "physical", serial: "14141JEC204922" }),
    "14141JEC204922",
  );
});

test("machineDeviceDetail: Android は avd があれば 'AVD: ' + avd(model があっても優先しない)", () => {
  assert.equal(
    machineDeviceDetail({ name: "エミュ1", platform: "android", avd: "Pixel 9(Android 16)", model: "Pixel 9" }),
    "AVD: Pixel 9(Android 16)",
  );
});

test("machineDeviceDetail: Android は avd/serial/model とも無ければ 'Android'", () => {
  assert.equal(machineDeviceDetail({ name: "謎", platform: "android" }), "Android");
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

// ---- removeDeviceFromRunProfile ----
// 実体(シミュレータ/AVD)を消したあと、実行プロファイルが指す台も外すための関数。
// プロファイルタブの「除去」からも、(platform, machine, name) が一致する全実行プロファイルへ
// 順に適用される形で使われる。

test("removeDeviceFromRunProfile: (platform, machine, name) 一致だけを外し、他マシンの同名は残す", () => {
  const profile = {
    app: "sut",
    devices: [
      { platform: "ios", machine: "local", name: "iPhone(iOS 27.0)01" },
      { platform: "ios", machine: "M1Max", name: "iPhone(iOS 27.0)01" },
      { platform: "ios", machine: "local", name: "iPhone(iOS 27.0)02" },
    ],
  };
  const result = removeDeviceFromRunProfile(profile, { platform: "ios", name: "iPhone(iOS 27.0)01" });
  assert.equal(result.removed, 1);
  assert.deepEqual(result.object.devices, [
    { platform: "ios", machine: "M1Max", name: "iPhone(iOS 27.0)01" },
    { platform: "ios", machine: "local", name: "iPhone(iOS 27.0)02" },
  ]);
  assert.equal(result.object.app, "sut", "他のキーは保持する");
});

test("removeDeviceFromRunProfile: machine 省略のキーは local として引く", () => {
  const result = removeDeviceFromRunProfile(
    {
      devices: [
        { platform: "android", name: "Pixel(Android 15)01" },
        { platform: "android", machine: "M1Ultra", name: "Pixel(Android 15)01" },
      ],
    },
    { platform: "android", name: "Pixel(Android 15)01" },
  );
  assert.equal(result.removed, 1);
  assert.deepEqual(result.object.devices, [
    { platform: "android", machine: "M1Ultra", name: "Pixel(Android 15)01" },
  ]);
});

test("removeDeviceFromRunProfile: platform が違えば同名でも消さない", () => {
  const result = removeDeviceFromRunProfile(
    { devices: [{ platform: "android", name: "同名" }, { platform: "ios", name: "同名" }] },
    { platform: "ios", name: "同名" },
  );
  assert.equal(result.removed, 1);
  assert.deepEqual(result.object.devices, [{ platform: "android", name: "同名" }]);
});

test("removeDeviceFromRunProfile: 対象が無ければ removed:0(書き戻さない判断に使う)", () => {
  const result = removeDeviceFromRunProfile(
    { devices: [{ platform: "ios", machine: "local", name: "他" }] },
    { platform: "ios", machine: "local", name: "対象" },
  );
  assert.equal(result.removed, 0);
});

test("removeDeviceFromRunProfile: devices が無い/不正形式でも壊さない", () => {
  assert.equal(removeDeviceFromRunProfile({ app: "M1" }, { platform: "ios", name: "x" }).removed, 0);
  assert.equal(removeDeviceFromRunProfile(null, { platform: "ios", name: "x" }), null);
  assert.equal(removeDeviceFromRunProfile([], { platform: "ios", name: "x" }), null);
  // 型不正の要素は対象外として保持する(消す方に倒すと利用者の記述を落とす)
  const odd = removeDeviceFromRunProfile(
    { devices: ["文字列", { platform: "ios", machine: "local", name: "x" }] },
    { platform: "ios", name: "x" },
  );
  assert.equal(odd.removed, 1);
  assert.deepEqual(odd.object.devices, ["文字列"]);
});

// ---- runProfileDeviceRefKey / orderedDeviceEntry ----

test("runProfileDeviceRefKey: (platform, machine, name) を1本のキーに畳む。machine 省略=手元", () => {
  assert.equal(
    runProfileDeviceRefKey({ platform: "ios", machine: "M1Max", name: "n" }),
    runProfileDeviceRefKey({ platform: "ios", machine: "M1Max", name: "n" }),
  );
  assert.notEqual(
    runProfileDeviceRefKey({ platform: "ios", name: "n" }),
    runProfileDeviceRefKey({ platform: "android", name: "n" }),
  );
  assert.notEqual(
    runProfileDeviceRefKey({ platform: "ios", machine: "M1Max", name: "n" }),
    runProfileDeviceRefKey({ platform: "ios", name: "n" }),
  );
});

test("orderedDeviceEntry: キー順は platform, machine, name, enabled、残りはアルファベット順", () => {
  const entry = orderedDeviceEntry({
    platform: "ios", name: "n", enabled: false, udid: "U", model: "M", osVersion: "iOS 27.0", port: 8100,
  });
  assert.deepEqual(Object.keys(entry), ["platform", "machine", "name", "enabled", "model", "osVersion", "port", "udid"]);
  assert.equal(entry.machine, "local", "手元も明示で書く");
});

test("orderedDeviceEntry: enabled=true のときは enabled キーを書かない", () => {
  const entry = orderedDeviceEntry({ platform: "android", machine: "M1Max", name: "n", enabled: true, avd: "Pixel_9" });
  assert.deepEqual(Object.keys(entry), ["platform", "machine", "name", "avd"]);
});

// ---- addDevicesToRunProfile ----

test("addDevicesToRunProfile: entries を devices[] 末尾に追記する(未知キー保持)", () => {
  const profile = { app: "sut", devices: [{ platform: "ios", machine: "local", name: "既存" }] };
  const result = addDevicesToRunProfile(
    profile,
    [{ platform: "ios", name: "新規", osVersion: "iOS 27.0", udid: "U-1", model: "iPhone 17 Pro" }],
    [],
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["新規"]);
  assert.equal(result.object.devices.length, 2);
  assert.equal(result.object.devices[1].name, "新規");
  assert.equal(result.object.devices[1].machine, "local");
  assert.equal(result.object.app, "sut", "他のキーは保持する");
});

test("addDevicesToRunProfile: 名前衝突はカタログ+このプロファイルの既存分+同一バッチ内を見て自動採番する", () => {
  const catalog = [{ platform: "ios", name: "シミュ1" }];
  const profile = { devices: [] };
  const result = addDevicesToRunProfile(
    profile,
    [
      { platform: "ios", name: "シミュ1" }, // カタログと衝突 → (2)
      { platform: "ios", name: "シミュ1" }, // バッチ内でも衝突 → (3)
    ],
    catalog,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.added, ["シミュ1 (2)", "シミュ1 (3)"]);
});

test("addDevicesToRunProfile: 別 machine の同名は衝突ではない", () => {
  const catalog = [{ platform: "ios", machine: "M1Max", name: "シミュ1" }];
  const result = addDevicesToRunProfile({ devices: [] }, [{ platform: "ios", name: "シミュ1" }], catalog);
  assert.deepEqual(result.added, ["シミュ1"]);
});

test("addDevicesToRunProfile: 非オブジェクトなら ok:false", () => {
  assert.equal(addDevicesToRunProfile(null, [], []).ok, false);
  assert.equal(addDevicesToRunProfile([], [], []).ok, false);
});

// ---- parseRunProfileForForm ----

test("parseRunProfileForForm: 正常な値は各フィールドをそのまま読み取る", () => {
  const parsed = parseRunProfileForForm({
    app: "sampleapp",
    devices: [
      { platform: "ios", name: "シミュ1" },
      { platform: "android", machine: "M1Max", name: "エミュ1", enabled: false },
    ],
    heal: true,
    textVisualCheck: false,
    screenLooksLike: false,
    containerInference: false,
    ocrTextVisualCheck: false,
    iosInappEngine: false,
    iosFastInput: true,
    iosPreActionWarmup: false,
    homeOnStart: true,
    playProtectBypass: false,
    enableAnimations: true,
    reportDir: "reports",
    updateWebView: true,
    wipeDataOnBloat: false,
    wipeDataThresholdGB: 1.5,
    recoverCpuFallbackToGpu: true,
    locale: "en_US",
    record: true,
    recordFailuresOnly: true,
    recordBitrateKbps: 2000,
    recordFullResolution: true,
    remoteControl: { workspace: "../sut-ec-mobile-workspace" },
  });
  assert.deepEqual(parsed, {
    app: "sampleapp",
    devices: [
      { platform: "ios", name: "シミュ1", enabled: true },
      { platform: "android", machine: "M1Max", name: "エミュ1", enabled: false },
    ],
    heal: true,
    textVisualCheck: false,
    screenLooksLike: false,
    containerInference: false,
    ocrTextVisualCheck: false,
    iosInappEngine: false,
    iosFastInput: true,
    iosPreActionWarmup: false,
    homeOnStart: true,
    playProtectBypass: false,
    enableAnimations: true,
    reportDir: "reports",
    updateWebView: true,
    wipeDataOnBloat: false,
    wipeDataThresholdGB: "1.5",
    recoverCpuFallbackToGpu: true,
    locale: "en_US",
    record: true,
    recordFailuresOnly: true,
    recordBitrateKbps: "2000",
    recordFullResolution: true,
    workspace: "../sut-ec-mobile-workspace",
  });
});

test("parseRunProfileForForm: 欠落キーは既定値(app/reportDir/locale/recordBitrateKbps/workspace=''、devices=[]、heal/screenLooksLike/textVisualCheck/containerInference=true、iosInappEngine=true、wipeDataOnBloat=true、wipeDataThresholdGB=''、record/recordFailuresOnly/recordFullResolution/iosFastInput/enableAnimations/recoverCpuFallbackToGpu=false、iosPreActionWarmup=true)", () => {
  const parsed = parseRunProfileForForm({});
  assert.deepEqual(parsed, {
    app: "",
    devices: [],
    heal: true,
    textVisualCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextVisualCheck: true,
    iosInappEngine: true,
    iosFastInput: false,
    iosPreActionWarmup: true,
    homeOnStart: true,
    playProtectBypass: true,
    enableAnimations: false,
    reportDir: "",
    updateWebView: true,
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "",
    recoverCpuFallbackToGpu: false,
    locale: "",
    record: false,
    recordFailuresOnly: false,
    recordBitrateKbps: "",
    recordFullResolution: false,
    workspace: "",
  });
});

test("parseRunProfileForForm: 型不正のキーは既定値扱い(heal が文字列、record/recordFailuresOnly/recordFullResolution/iosFastInput が文字列、remoteControl が非オブジェクト 等)", () => {
  const parsed = parseRunProfileForForm({
    app: null,
    devices: "not-an-array",
    heal: "true",
    textVisualCheck: "false",
    screenLooksLike: "false",
    containerInference: "false",
    ocrTextVisualCheck: "true",
    iosInappEngine: "false",
    iosFastInput: "true",
    reportDir: false,
    wipeDataOnBloat: "false",
    wipeDataThresholdGB: {},
    recoverCpuFallbackToGpu: "true",
    locale: 123,
    record: "true",
    recordFailuresOnly: "true",
    recordBitrateKbps: {},
    recordFullResolution: "true",
    remoteControl: "not-an-object",
  });
  assert.deepEqual(parsed, {
    app: "",
    devices: [],
    heal: true,
    textVisualCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextVisualCheck: true,
    iosInappEngine: true,
    iosFastInput: false,
    iosPreActionWarmup: true,
    homeOnStart: true,
    playProtectBypass: true,
    enableAnimations: false,
    reportDir: "",
    updateWebView: true,
    wipeDataOnBloat: true,
    wipeDataThresholdGB: "",
    recoverCpuFallbackToGpu: false,
    locale: "",
    record: false,
    recordFailuresOnly: false,
    recordBitrateKbps: "",
    recordFullResolution: false,
    workspace: "",
  });
});

test("parseRunProfileForForm: 旧キー screenIs は新キーが無いときだけ読む(改名前のプロファイル)", () => {
  // 優先順は Sources/FTCore/RunProfile.swift の effectiveScreenLooksLike と同じ。
  // 読み落とすと、受け手が OFF にしていた設定が画面上だけ ON へ戻る
  assert.equal(parseRunProfileForForm({ screenIs: false }).screenLooksLike, false);
  assert.equal(parseRunProfileForForm({ screenLooksLike: true, screenIs: false }).screenLooksLike, true);
  assert.equal(parseRunProfileForForm({ screenIs: "false" }).screenLooksLike, true, "型不正は既定 true");
  assert.equal(parseRunProfileForForm({}).screenLooksLike, true);
});

test("updateRunProfileInObject: 保存すると旧キー screenIs は消える(同じ設定が2つのキーに残らない)", () => {
  const saved = updateRunProfileInObject(
    { screenIs: false, app: "a" },
    { ...BASE_RUN_PROFILE_FIELDS, screenLooksLike: true });
  assert.equal(saved.ok, true);
  assert.equal(saved.object.screenLooksLike, true);
  assert.ok(!("screenIs" in saved.object), `旧キーが残っている: ${JSON.stringify(saved.object)}`);
});

test("updateRunProfileInObject: 保存すると撤去したキー triage は消える(旧テンプレートが必ず書いていた)", () => {
  const saved = updateRunProfileInObject(
    { triage: true, app: "a", customKey: 1 },
    { ...BASE_RUN_PROFILE_FIELDS });
  assert.equal(saved.ok, true);
  assert.ok(!("triage" in saved.object), `撤去したキーが残っている: ${JSON.stringify(saved.object)}`);
  assert.equal(saved.object.customKey, 1, "他の未知のキーは引き継ぐ");
});

test("updateRunProfileInObject: 保存すると撤去したキー fm/ocr は値に関わらず消える(旧 GUI が必ず書いていた)", () => {
  const saved = updateRunProfileInObject(
    { fm: true, ocr: false, app: "a" },
    { ...BASE_RUN_PROFILE_FIELDS });
  assert.equal(saved.ok, true);
  assert.ok(!("fm" in saved.object), `撤去したキーが残っている: ${JSON.stringify(saved.object)}`);
  assert.ok(!("ocr" in saved.object), `撤去したキーが残っている: ${JSON.stringify(saved.object)}`);
});

test("parseRunProfileForForm: remoteControl はネストしたオブジェクトから読む(欠落/非オブジェクト/非文字列 は既定値'')", () => {
  assert.equal(parseRunProfileForForm({ remoteControl: { workspace: "../ws" } }).workspace, "../ws");
  assert.equal(parseRunProfileForForm({}).workspace, "");
  assert.equal(parseRunProfileForForm({ remoteControl: null }).workspace, "");
  assert.equal(parseRunProfileForForm({ remoteControl: [] }).workspace, "");
  assert.equal(parseRunProfileForForm({ remoteControl: {} }).workspace, "");
  assert.equal(parseRunProfileForForm({ remoteControl: { workspace: 123 } }).workspace, "");
  // remoteControl に既知キー以外があっても無視するだけで壊れない(将来の拡張キー)
  assert.equal(parseRunProfileForForm({ remoteControl: { workspace: "../ws", other: 1 } }).workspace, "../ws");
});

test("parseRunProfileForForm: heal/screenLooksLike/containerInference は boolean ならそのまま返し、欠落/非 boolean は既定値 true", () => {
  for (const key of ["heal", "screenLooksLike", "containerInference"]) {
    assert.equal(parseRunProfileForForm({ [key]: false })[key], false);
    assert.equal(parseRunProfileForForm({ [key]: true })[key], true);
    assert.equal(parseRunProfileForForm({})[key], true);
    assert.equal(parseRunProfileForForm({ [key]: "false" })[key], true);
  }
});

// **既定は 2026-09-03 に false → true(ユーザー決定)**。既定値は Swift 側
// (RunProfile.swift の `runDoc.textVisualCheck ?? true`)と JSON スキーマと3箇所で一致させる
test("parseRunProfileForForm: textVisualCheck は boolean ならそのまま返し、欠落/非 boolean は既定値 true", () => {
  assert.equal(parseRunProfileForForm({ textVisualCheck: true }).textVisualCheck, true);
  assert.equal(parseRunProfileForForm({ textVisualCheck: false }).textVisualCheck, false);
  assert.equal(parseRunProfileForForm({}).textVisualCheck, true);
  assert.equal(parseRunProfileForForm({ textVisualCheck: "true" }).textVisualCheck, true);
});

test("parseRunProfileForForm: homeOnStart は boolean ならそのまま返し、欠落/非 boolean は既定値 true(= 撃つ)", () => {
  assert.equal(parseRunProfileForForm({ homeOnStart: false }).homeOnStart, false);
  assert.equal(parseRunProfileForForm({ homeOnStart: true }).homeOnStart, true);
  assert.equal(parseRunProfileForForm({}).homeOnStart, true, "欠落なら撃つ(凍結対策は既定 ON)");
  assert.equal(parseRunProfileForForm({ homeOnStart: "yes" }).homeOnStart, true);
});

test("parseRunProfileForForm: enableAnimations は boolean ならそのまま返し、欠落/非 boolean は既定値 false(= アニメーション無効化)", () => {
  assert.equal(parseRunProfileForForm({ enableAnimations: true }).enableAnimations, true);
  assert.equal(parseRunProfileForForm({ enableAnimations: false }).enableAnimations, false);
  assert.equal(parseRunProfileForForm({}).enableAnimations, false);
  assert.equal(parseRunProfileForForm({ enableAnimations: "true" }).enableAnimations, false);
});

test("parseRunProfileForForm: iosFastInput は boolean ならそのまま返し、欠落/非 boolean は既定値 false", () => {
  assert.equal(parseRunProfileForForm({ iosFastInput: true }).iosFastInput, true);
  assert.equal(parseRunProfileForForm({}).iosFastInput, false);
  assert.equal(parseRunProfileForForm({ iosFastInput: "true" }).iosFastInput, false);
});

test("parseRunProfileForForm: recordBitrateKbps は number なら String() 化、string ならそのまま返す", () => {
  assert.equal(parseRunProfileForForm({ recordBitrateKbps: 1500 }).recordBitrateKbps, "1500");
  assert.equal(parseRunProfileForForm({ recordBitrateKbps: "3000" }).recordBitrateKbps, "3000");
});

test("parseRunProfileForForm: devices は platform 不正/name が非文字列/オブジェクトでない要素をスキップする", () => {
  const parsed = parseRunProfileForForm({
    devices: [
      { platform: "ios", name: "シミュ1" },
      { platform: "ios", name: 123 },
      "not-an-object",
      { other: "x" },
      { name: "platform欠落" },
      { platform: "windows", name: "不正platform" },
      { platform: "android", name: "エミュ1" },
    ],
  });
  assert.deepEqual(parsed.devices, [
    { platform: "ios", name: "シミュ1", enabled: true },
    { platform: "android", name: "エミュ1", enabled: true },
  ]);
});

test("parseRunProfileForForm: devices の machine は 'local'/''/省略を手元(undefined)へ正規化する", () => {
  const parsed = parseRunProfileForForm({
    devices: [
      { platform: "ios", machine: "local", name: "A" },
      { platform: "ios", machine: "", name: "B" },
      { platform: "ios", name: "C" },
      { platform: "ios", machine: "M1Max", name: "D" },
    ],
  });
  assert.deepEqual(parsed.devices.map((d) => d.machine), [undefined, undefined, undefined, "M1Max"]);
});

test("parseRunProfileForForm: devices の enabled は false のときだけ false、それ以外は true", () => {
  const parsed = parseRunProfileForForm({
    devices: [
      { platform: "ios", name: "A", enabled: false },
      { platform: "ios", name: "B", enabled: true },
      { platform: "ios", name: "C" },
      { platform: "ios", name: "D", enabled: "false" },
    ],
  });
  assert.deepEqual(parsed.devices.map((d) => d.enabled), [false, true, true, true]);
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

test("parseRunProfileForForm: recordFailuresOnly/recordFullResolution は boolean ならそのまま返し、欠落/非 boolean は既定値 false", () => {
  assert.equal(parseRunProfileForForm({ recordFailuresOnly: true }).recordFailuresOnly, true);
  assert.equal(parseRunProfileForForm({}).recordFailuresOnly, false);
  assert.equal(parseRunProfileForForm({ recordFailuresOnly: "true" }).recordFailuresOnly, false);
  assert.equal(parseRunProfileForForm({ recordFullResolution: true }).recordFullResolution, true);
  assert.equal(parseRunProfileForForm({}).recordFullResolution, false);
  assert.equal(parseRunProfileForForm({ recordFullResolution: "true" }).recordFullResolution, false);
});

test("parseRunProfileForForm: トップレベルが非オブジェクト(配列含む)なら null", () => {
  assert.equal(parseRunProfileForForm(null), null);
  assert.equal(parseRunProfileForForm("string"), null);
  assert.equal(parseRunProfileForForm([{ app: "a" }]), null);
});

// ---- parseAppProfileForForm ----
// common は自動インストール(autoInstall。true のときだけ "true"、それ以外[false/欠落/型不正]は
// 既定=無効を表す "false")の1フィールドのみ(表示名は継承しないため common には無い)、
// ios/android は表示名・アプリID・パッケージパスの3フィールド(autoInstall は common に一本化
// されたため持たない。2026-07-11 指示)。

test("parseAppProfileForForm: 正常な値を読み取る(common は自動インストールのみ、ios/android は3フィールド)", () => {
  const parsed = parseAppProfileForForm({
    common: { appName: "廃止済み", app: "com.example.sampleapp", appPath: "path/to.app", autoInstall: true },
    ios: {
      appName: "サンプル(iOS)",
      app: "com.example.sampleapp.ios",
      appPath: "path/to-ios.app",
      appPathPhysical: "path/to-ios-device.app",
      autoInstall: false,
    },
    android: {
      appName: "サンプル(Android)",
      app: "com.example.sampleapp.android",
      appPath: "path/to.apk",
      autoInstall: true,
    },
  });
  assert.deepEqual(parsed, {
    // common の appName/app/appPath は廃止のため読み取らない(autoInstall のみ反映される)。
    common: { autoInstall: "true" },
    // ios/android の autoInstall は common に一本化されたため読み取らない(残っていても無視)。
    ios: {
      appName: "サンプル(iOS)",
      app: "com.example.sampleapp.ios",
      appPath: "path/to-ios.app",
      appPathPhysical: "path/to-ios-device.app",
    },
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
  assert.deepEqual(parsed, {
    common: { autoInstall: "false" },
    ios: { ...emptyPlatform, appPathPhysical: "" },
    android: emptyPlatform,
  });
});

test("parseAppProfileForForm: セクションが非オブジェクト(配列含む)なら空のセクション扱い", () => {
  const parsed = parseAppProfileForForm({ common: "invalid", ios: null, android: ["a"] });
  const emptyPlatform = { appName: "", app: "", appPath: "" };
  assert.deepEqual(parsed, {
    common: { autoInstall: "false" },
    ios: { ...emptyPlatform, appPathPhysical: "" },
    android: emptyPlatform,
  });
});

test("parseAppProfileForForm: appPathPhysical(実機に配るパッケージ)は ios のみ読み取る(android は欄が無い)", () => {
  const parsed = parseAppProfileForForm({
    ios: { appPathPhysical: "path/to-ios-device.app" },
    android: { appPathPhysical: "path/to-device.apk" },
  });
  assert.equal(parsed.ios.appPathPhysical, "path/to-ios-device.app");
  assert.equal("appPathPhysical" in parsed.android, false);
  // 型不正・欠落は既定の空文字。
  assert.equal(parseAppProfileForForm({ ios: { appPathPhysical: 1 } }).ios.appPathPhysical, "");
  assert.equal(parseAppProfileForForm({ ios: {} }).ios.appPathPhysical, "");
});

test("parseAppProfileForForm: フィールドの型不正は既定値扱い(appName が数値、app/appPath が欠落 等)", () => {
  const parsed = parseAppProfileForForm({
    common: { appName: 123, app: "irrelevant", autoInstall: "true" }, // autoInstall は文字列(型不正)なので既定 false 扱い
    ios: { appName: 123, app: null },
  });
  assert.deepEqual(parsed.common, { autoInstall: "false" });
  assert.deepEqual(parsed.ios, { appName: "", app: "", appPath: "", appPathPhysical: "" });
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
  app: "sampleapp",
  devices: [
    { platform: "ios", name: "シミュ1", enabled: true },
    { platform: "android", name: "エミュ1", enabled: true },
  ],
  heal: false,
  textVisualCheck: true,
  screenLooksLike: true,
  containerInference: true,
  ocrTextVisualCheck: true,
  iosInappEngine: true,
  iosFastInput: false,
  iosPreActionWarmup: true,
  homeOnStart: true,
  enableAnimations: false,
  reportDir: "reports",
  updateWebView: true,
  wipeDataOnBloat: true,
  wipeDataThresholdGB: "1",
  locale: "ja_JP",
  record: false,
  recordFailuresOnly: false,
  recordBitrateKbps: "",
  recordFullResolution: false,
  workspace: "",
};

test("updateRunProfileInObject: 基本更新(app/heal/textVisualCheck/screenLooksLike/containerInference/iosInappEngine/wipeDataOnBloat/reportDir)", () => {
  const result = updateRunProfileInObject({ app: "old", devices: [], heal: false, reportDir: "old" }, BASE_RUN_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.app, "sampleapp");
  assert.equal(result.object.heal, false);
  assert.equal(result.object.textVisualCheck, true);
  assert.equal(result.object.screenLooksLike, true);
  assert.equal(result.object.containerInference, true);
  assert.equal(result.object.iosInappEngine, true);
  assert.equal(result.object.wipeDataOnBloat, true);
  assert.equal(result.object.wipeDataThresholdGB, 1);
  assert.equal(result.object.reportDir, "reports");
  assert.equal(result.object.locale, "ja_JP");
  // machine は常に書く(手元は "local")。既存に無い(=新規)エントリなので platform 順に組み立てられる
  assert.deepEqual(result.object.devices, [
    { platform: "ios", machine: "local", name: "シミュ1" },
    { platform: "android", machine: "local", name: "エミュ1" },
  ]);
  assert.equal("record" in result.object, false); // record:false はキーを書かない
  assert.equal("recordFailuresOnly" in result.object, false);
  assert.equal("recordBitrateKbps" in result.object, false);
  assert.equal("recordFullResolution" in result.object, false);
  assert.equal("iosFastInput" in result.object, false);
  assert.equal("enableAnimations" in result.object, false); // 既定(無効化)はキーを書かない
  assert.equal("remoteControl" in result.object, false); // 3欄とも未設定ならセクション自体を書かない
});

test("updateRunProfileInObject: remoteControl.workspace は空文字でセクション削除、値があれば { workspace } を書く、既存の他キーは保つ", () => {
  const removed = updateRunProfileInObject(
    { remoteControl: { workspace: "../old-ws" } },
    { ...BASE_RUN_PROFILE_FIELDS, workspace: "" },
  );
  assert.equal(removed.ok, true);
  assert.equal("remoteControl" in removed.object, false);

  const addedFromScratch = updateRunProfileInObject(
    {},
    { ...BASE_RUN_PROFILE_FIELDS, workspace: "../sut-ec-mobile-workspace" },
  );
  assert.equal(addedFromScratch.ok, true);
  assert.deepEqual(addedFromScratch.object.remoteControl, { workspace: "../sut-ec-mobile-workspace" });

  // trim される(前後空白は保存しない)
  const trimmed = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, workspace: "  ../ws  " });
  assert.equal(trimmed.object.remoteControl.workspace, "../ws");

  // 未知キー(将来の拡張分)は workspace 更新後も保たれる
  const preserved = updateRunProfileInObject(
    { remoteControl: { workspace: "../old-ws", futureKey: true } },
    { ...BASE_RUN_PROFILE_FIELDS, workspace: "../new-ws" },
  );
  assert.equal(preserved.ok, true);
  assert.deepEqual(preserved.object.remoteControl, { workspace: "../new-ws", futureKey: true });
});

test("updateRunProfileInObject: record/recordFailuresOnly/recordFullResolution/iosFastInput/enableAnimations は true のときのみ書き込み、false なら既存キーごと削除する", () => {
  for (const key of ["record", "recordFailuresOnly", "recordFullResolution", "iosFastInput", "enableAnimations"]) {
    const enabled = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, [key]: true });
    assert.equal(enabled.ok, true);
    assert.equal(enabled.object[key], true, `${key}: true で書き込まれるべき`);

    const disabledFromScratch = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, [key]: false });
    assert.equal(disabledFromScratch.ok, true);
    assert.equal(key in disabledFromScratch.object, false, `${key}: false ならキー無しであるべき`);

    const disabledFromExisting = updateRunProfileInObject({ [key]: true }, { ...BASE_RUN_PROFILE_FIELDS, [key]: false });
    assert.equal(disabledFromExisting.ok, true);
    assert.equal(key in disabledFromExisting.object, false, `${key}: 既存 true → false で削除されるべき`);
  }
});

test("updateRunProfileInObject: heal/textVisualCheck/screenLooksLike/containerInference は true/false どちらも常時書き込む(キー削除しない)", () => {
  for (const key of ["heal", "textVisualCheck", "screenLooksLike", "containerInference"]) {
    const enabled = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, [key]: true });
    assert.equal(enabled.object[key], true, `${key}: true で書き込まれるべき`);

    const disabled = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, [key]: false });
    assert.equal(disabled.object[key], false, `${key}: false でも明示的に書き込まれるべき`);
  }
});

test("updateRunProfileInObject: recordBitrateKbps は空文字でキー削除、正の整数で number 化、不正値でエラー", () => {
  const removed = updateRunProfileInObject(
    { recordBitrateKbps: 2000 },
    { ...BASE_RUN_PROFILE_FIELDS, recordBitrateKbps: "" },
  );
  assert.equal(removed.ok, true);
  assert.equal("recordBitrateKbps" in removed.object, false);

  const added = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, recordBitrateKbps: "3000" });
  assert.equal(added.ok, true);
  assert.equal(added.object.recordBitrateKbps, 3000);
  assert.equal(typeof added.object.recordBitrateKbps, "number");

  for (const invalid of ["0", "-1", "1.5", "abc"]) {
    const result = updateRunProfileInObject({}, { ...BASE_RUN_PROFILE_FIELDS, recordBitrateKbps: invalid });
    assert.equal(result.ok, false, `recordBitrateKbps=${invalid} は不正値としてエラーになるべき`);
    assert.match(result.error, /recordBitrateKbps/);
  }
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

test("updateRunProfileInObject: app/reportDir は空文字ならキー削除する", () => {
  const result = updateRunProfileInObject(
    { app: "sampleapp", devices: [], heal: false, reportDir: "reports" },
    { ...BASE_RUN_PROFILE_FIELDS, app: "", reportDir: "" },
  );
  assert.equal(result.ok, true);
  assert.equal("app" in result.object, false);
  assert.equal("reportDir" in result.object, false);
});

// defaultTimeout は GUI のフォーム欄を持たない(RunProfileFormFields に無い)。result は
// `{ ...source }` から始まるため、既存 JSON の値はフォーム保存で一切変更されず保たれる。
test("updateRunProfileInObject: defaultTimeout はフォームに欄が無いため、既存の値をそのまま保つ", () => {
  const preserved = updateRunProfileInObject({ defaultTimeout: 8 }, BASE_RUN_PROFILE_FIELDS);
  assert.equal(preserved.ok, true);
  assert.equal(preserved.object.defaultTimeout, 8);

  const untouched = updateRunProfileInObject({}, BASE_RUN_PROFILE_FIELDS);
  assert.equal(untouched.ok, true);
  assert.equal("defaultTimeout" in untouched.object, false);
});

test("updateRunProfileInObject: devices は既存の同名エントリ(未知キー込み)を再利用し、新規名は orderedDeviceEntry で追加する", () => {
  const profile = {
    devices: [
      { platform: "ios", name: "シミュ1", note: "keep-me" },
      { platform: "ios", name: "旧デバイス" },
    ],
  };
  const result = updateRunProfileInObject(
    profile,
    {
      ...BASE_RUN_PROFILE_FIELDS,
      devices: [
        { platform: "ios", name: "シミュ1", enabled: true },
        { platform: "ios", name: "新デバイス", enabled: true },
      ],
    },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [
    { platform: "ios", name: "シミュ1", note: "keep-me", machine: "local" },
    { platform: "ios", machine: "local", name: "新デバイス" },
  ]);
});

test("updateRunProfileInObject: devices は fields.devices の順序で再構成する", () => {
  const profile = { devices: [{ platform: "ios", name: "A" }, { platform: "ios", name: "B" }] };
  const result = updateRunProfileInObject(
    profile,
    {
      ...BASE_RUN_PROFILE_FIELDS,
      devices: [{ platform: "ios", name: "B", enabled: true }, { platform: "ios", name: "A", enabled: true }],
    },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [
    { platform: "ios", name: "B", machine: "local" },
    { platform: "ios", name: "A", machine: "local" },
  ]);
});

test("updateRunProfileInObject: チェックを外すと enabled:false で残り、既存の除去はしない", () => {
  const profile = { devices: [{ platform: "ios", name: "A" }] };
  const result = updateRunProfileInObject(
    profile,
    { ...BASE_RUN_PROFILE_FIELDS, devices: [{ platform: "ios", name: "A", enabled: false }] },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [{ platform: "ios", name: "A", machine: "local", enabled: false }]);
});

test("updateRunProfileInObject: 未知キー(トップレベル)を保持する", () => {
  const profile = { app: "old", devices: [], futureFeature: { nested: true } };
  const result = updateRunProfileInObject(profile, BASE_RUN_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.futureFeature, { nested: true });
});

test("updateRunProfileInObject: devices 要素内の未知キーを保持する(再利用時)", () => {
  const profile = { devices: [{ platform: "ios", name: "シミュ1", customFlag: true, nested: { a: 1 } }] };
  const result = updateRunProfileInObject(
    profile, { ...BASE_RUN_PROFILE_FIELDS, devices: [{ platform: "ios", name: "シミュ1", enabled: true }] });
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.devices, [
    { platform: "ios", name: "シミュ1", customFlag: true, nested: { a: 1 }, machine: "local" },
  ]);
});

test("updateRunProfileInObject: トップレベルがオブジェクトでなければ(配列含む)エラー", () => {
  assert.equal(updateRunProfileInObject(null, BASE_RUN_PROFILE_FIELDS).ok, false);
  assert.equal(updateRunProfileInObject([{ app: "a" }], BASE_RUN_PROFILE_FIELDS).ok, false);
  assert.equal(updateRunProfileInObject("string", BASE_RUN_PROFILE_FIELDS).ok, false);
});

// ---- updateAppProfileInObject ----
// common は自動インストール(autoInstall。"true" は boolean true をセット、"false" は既定[無効]と
// 同値なのでキー削除)のみを書き込む(appName/app/appPath は廃止に伴い常に削除。表示名は
// ios/android のそれぞれに書き、common からは継承しない)。ios/android は表示名・アプリID・
// パッケージパスのみを書き込む(autoInstall は common に一本化されたため、残っていても廃止に
// 伴い常に削除する。2026-07-11 指示)。

const BASE_APP_PROFILE_FIELDS = {
  common: { autoInstall: "false" },
  ios: { appName: "", app: "", appPath: "", appPathPhysical: "" },
  android: { appName: "", app: "", appPath: "" },
};

test("updateAppProfileInObject: 基本更新(common は自動インストールのみ)", () => {
  const result = updateAppProfileInObject({}, { ...BASE_APP_PROFILE_FIELDS, common: { autoInstall: "true" } });
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, { autoInstall: true });
});

test("updateAppProfileInObject: 既存の common.appName は保存のたびに削除される(Swift 側の未知キー警告を防ぐ)", () => {
  const result = updateAppProfileInObject(
    { common: { appName: "old" } },
    BASE_APP_PROFILE_FIELDS,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, {});
});

test("updateAppProfileInObject: common に残った appName/app/appPath は廃止に伴い常に削除する", () => {
  const result = updateAppProfileInObject(
    { common: { appName: "old", app: "old.app", appPath: "old/path", autoInstall: true } },
    { ...BASE_APP_PROFILE_FIELDS, common: { autoInstall: "true" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, { autoInstall: true });
});

test("updateAppProfileInObject: common の autoInstall・healthCheckURL は appName 削除後も保たれる", () => {
  const result = updateAppProfileInObject(
    { common: { appName: "old", autoInstall: true, healthCheckURL: "http://localhost:8090/" } },
    { ...BASE_APP_PROFILE_FIELDS, common: { autoInstall: "true" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.common, { autoInstall: true, healthCheckURL: "http://localhost:8090/" });
});

test("updateAppProfileInObject: common の autoInstall は2値('true' は boolean true をセット/'false' はキー削除)", () => {
  const removed = updateAppProfileInObject(
    { common: { autoInstall: true } },
    BASE_APP_PROFILE_FIELDS,
  );
  assert.equal("autoInstall" in removed.object.common, false);

  const trueResult = updateAppProfileInObject({}, { ...BASE_APP_PROFILE_FIELDS, common: { autoInstall: "true" } });
  assert.equal(trueResult.object.common.autoInstall, true);
});

test("updateAppProfileInObject: ios/android の appName/app/appPath は空文字ならキー削除する", () => {
  const result = updateAppProfileInObject(
    { ios: { appName: "old", app: "old", appPath: "old" } },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "", appPathPhysical: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: ios/android に残った autoInstall は common への一本化に伴い常に削除する", () => {
  const result = updateAppProfileInObject(
    { ios: { autoInstall: true } },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "", appPathPhysical: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: 元に無い common セクションは autoInstall 'false' のままなら作らない", () => {
  const result = updateAppProfileInObject({}, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal("common" in result.object, false);
});

test("updateAppProfileInObject: 元に無い ios/android セクションは全フィールド既定値のままなら作らない", () => {
  const result = updateAppProfileInObject({}, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal("ios" in result.object, false);
  assert.equal("android" in result.object, false);
});

test("updateAppProfileInObject: 元に無いセクションでも1つでも値があれば作る(common は autoInstall 'true'、ios/android は appName/app/appPath のいずれか)", () => {
  const byCommonAutoInstall = updateAppProfileInObject(
    {},
    { ...BASE_APP_PROFILE_FIELDS, common: { autoInstall: "true" } },
  );
  assert.deepEqual(byCommonAutoInstall.object.common, { autoInstall: true });

  const byField = updateAppProfileInObject(
    {},
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "com.example.ios", appPath: "", appPathPhysical: "" } },
  );
  assert.deepEqual(byField.object.ios, { app: "com.example.ios" });
});

test("updateAppProfileInObject: 既存の空セクションは空のまま保持する", () => {
  const result = updateAppProfileInObject(
    { ios: {} },
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "", appPathPhysical: "" } },
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.ios, {});
});

test("updateAppProfileInObject: ios の appPathPhysical(実機に配るパッケージ)は書き込み・空文字なら削除する", () => {
  const written = updateAppProfileInObject(
    {},
    { ...BASE_APP_PROFILE_FIELDS, ios: { appName: "", app: "", appPath: "", appPathPhysical: "path/to-device.app" } },
  );
  assert.equal(written.ok, true);
  assert.deepEqual(written.object.ios, { appPathPhysical: "path/to-device.app" });

  const removed = updateAppProfileInObject({ ios: { appPathPhysical: "old.app" } }, BASE_APP_PROFILE_FIELDS);
  assert.equal(removed.ok, true);
  assert.deepEqual(removed.object.ios, {});
});

test("updateAppProfileInObject: 手書きの android.appPathPhysical は欄が無いため保存で消さない", () => {
  const result = updateAppProfileInObject({ android: { appPathPhysical: "path/to-device.apk" } }, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.deepEqual(result.object.android, { appPathPhysical: "path/to-device.apk" });
});

test("updateAppProfileInObject: 未知キー(トップレベル)を保持する", () => {
  const profile = { common: {}, customTopKey: "keep-me" };
  const result = updateAppProfileInObject(profile, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.customTopKey, "keep-me");
});

test("updateAppProfileInObject: 未知キー(セクション内)を保持する(appName は未知キーではなく廃止キーとして削除する)", () => {
  const profile = { common: { customKey: "keep-me", appName: "old" } };
  const result = updateAppProfileInObject(profile, BASE_APP_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.common.customKey, "keep-me");
  assert.equal("appName" in result.object.common, false);
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

test("isDeviceCatalogJson: downloadableSystemImages/downloadableError は旧 CLI 互換で省略可", () => {
  // 欠落(旧 CLI)は従来どおり true
  assert.equal(isDeviceCatalogJson(VALID_DEVICE_CATALOG), true);

  const withDownloadable = structuredClone(VALID_DEVICE_CATALOG);
  withDownloadable.android.downloadableSystemImages = [
    {
      abi: "arm64-v8a", apiLevel: 36, license: "android-sdk-arm-dbt-license",
      package: "system-images;android-36;google_apis;arm64-v8a",
      sizeBytes: 1900000000, tag: "google_apis", versionName: "Android 16",
    },
  ];
  withDownloadable.android.downloadableError = null;
  assert.equal(isDeviceCatalogJson(withDownloadable), true);

  // license/sizeBytes は null を許容する(読めなかった=不明。断定しない)
  const unknownSizeAndLicense = structuredClone(withDownloadable);
  unknownSizeAndLicense.android.downloadableSystemImages[0].license = null;
  unknownSizeAndLicense.android.downloadableSystemImages[0].sizeBytes = null;
  assert.equal(isDeviceCatalogJson(unknownSizeAndLicense), true);

  const withError = structuredClone(VALID_DEVICE_CATALOG);
  withError.android.downloadableError = "sdkmanager --list に失敗しました";
  assert.equal(isDeviceCatalogJson(withError), true);
});

test("isDeviceCatalogJson: downloadableSystemImages の要素の型不正は全体を false にする", () => {
  const badAbi = structuredClone(VALID_DEVICE_CATALOG);
  badAbi.android.downloadableSystemImages = [{
    abi: 1, apiLevel: 36, license: null,
    package: "system-images;android-36;google_apis;arm64-v8a",
    sizeBytes: null, tag: "google_apis", versionName: "Android 16",
  }];
  assert.equal(isDeviceCatalogJson(badAbi), false);

  const badSizeBytes = structuredClone(VALID_DEVICE_CATALOG);
  badSizeBytes.android.downloadableSystemImages = [{
    abi: "arm64-v8a", apiLevel: 36, license: null,
    package: "system-images;android-36;google_apis;arm64-v8a",
    sizeBytes: "1900000000", tag: "google_apis", versionName: "Android 16",
  }];
  assert.equal(isDeviceCatalogJson(badSizeBytes), false);

  const badDownloadableError = structuredClone(VALID_DEVICE_CATALOG);
  badDownloadableError.android.downloadableError = 123;
  assert.equal(isDeviceCatalogJson(badDownloadableError), false);
});

// ---- isInstalledDevicesJson ----
// `fleetest api installed-devices` の stdout(「+既存から選択」モーダルが使う)。

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

// ---- isInstallSystemImageEvent ----

test("isInstallSystemImageEvent: log/finished(ok:true/false)の正常な値を true と判定する", () => {
  assert.equal(isInstallSystemImageEvent({ kind: "log", message: "ダウンロード中..." }), true);
  assert.equal(isInstallSystemImageEvent({ kind: "finished", ok: true, error: null }), true);
  assert.equal(isInstallSystemImageEvent({ kind: "finished", ok: false, error: "失敗しました" }), true);
});

test("isInstallSystemImageEvent: create-device と違い device フィールドは無い契約(あっても無視して true)", () => {
  assert.equal(
    isInstallSystemImageEvent({ kind: "finished", ok: true, error: null, device: { avd: null, udid: null } }),
    true,
  );
});

test("isInstallSystemImageEvent: 未知のkind・フィールド欠落/型不一致は false", () => {
  assert.equal(isInstallSystemImageEvent({ kind: "unknown" }), false);
  assert.equal(isInstallSystemImageEvent({ kind: "log", message: 123 }), false);
  assert.equal(isInstallSystemImageEvent({ kind: "finished", ok: "true", error: null }), false);
  assert.equal(isInstallSystemImageEvent({ kind: "finished", ok: true, error: 123 }), false);
  assert.equal(isInstallSystemImageEvent(null), false);
});

// ---- installSystemImageApiArgs ----

test("installSystemImageApiArgs: --package と --accept-licenses を渡す", () => {
  assert.deepEqual(
    installSystemImageApiArgs("system-images;android-36;google_apis;arm64-v8a"),
    ["api", "install-system-image", "--package", "system-images;android-36;google_apis;arm64-v8a", "--accept-licenses"],
  );
});

// ---- deleteDeviceApiArgs ----

test("deleteDeviceApiArgs: iOS は --udid、Android は --avd を渡す", () => {
  assert.deepEqual(
    deleteDeviceApiArgs("ios", "ABCDEFGH-1234"),
    ["api", "delete-device", "--platform", "ios", "--udid", "ABCDEFGH-1234"],
  );
  assert.deepEqual(
    deleteDeviceApiArgs("android", "Pixel_9_API_37"),
    ["api", "delete-device", "--platform", "android", "--avd", "Pixel_9_API_37"],
  );
});

test("deleteDeviceApiArgs: プロジェクトを渡したら --project を付ける(referencedBy の解決を運任せにしない)", () => {
  assert.deepEqual(
    deleteDeviceApiArgs("ios", "ABCDEFGH-1234", "sut-ec-mobile"),
    ["api", "delete-device", "--platform", "ios", "--udid", "ABCDEFGH-1234", "--project", "sut-ec-mobile"],
  );
  // 解決できなかったときは付けない(CLI 側の推測に任せる。削除自体は続行される)
  assert.deepEqual(
    deleteDeviceApiArgs("android", "Pixel_9_API_37", ""),
    ["api", "delete-device", "--platform", "android", "--avd", "Pixel_9_API_37"],
  );
});

// ---- isDeleteDeviceEvent ----

test("isDeleteDeviceEvent: log/finished(ok:true/false、referencedBy あり/なし)の正常な値を true と判定する", () => {
  assert.equal(isDeleteDeviceEvent({ kind: "log", message: "削除しています..." }), true);
  assert.equal(isDeleteDeviceEvent({ kind: "finished", ok: true, error: null }), true);
  assert.equal(isDeleteDeviceEvent({ kind: "finished", ok: true, error: null, referencedBy: [] }), true);
  assert.equal(
    isDeleteDeviceEvent({ kind: "finished", ok: true, error: null, referencedBy: ["M1", "M2"] }),
    true,
  );
  assert.equal(isDeleteDeviceEvent({ kind: "finished", ok: false, error: "起動中のため削除できません" }), true);
});

test("isDeleteDeviceEvent: 未知のkind・フィールド欠落/型不一致は false", () => {
  assert.equal(isDeleteDeviceEvent({ kind: "unknown" }), false);
  assert.equal(isDeleteDeviceEvent({ kind: "log" }), false);
  assert.equal(isDeleteDeviceEvent({ kind: "log", message: 123 }), false);
  assert.equal(isDeleteDeviceEvent({ kind: "finished", ok: "true", error: null }), false);
  assert.equal(isDeleteDeviceEvent({ kind: "finished", ok: false, error: 123 }), false);
  assert.equal(
    isDeleteDeviceEvent({ kind: "finished", ok: true, error: null, referencedBy: ["M1", 2] }),
    false,
  );
  assert.equal(
    isDeleteDeviceEvent({ kind: "finished", ok: true, error: null, referencedBy: "M1" }),
    false,
  );
  assert.equal(isDeleteDeviceEvent(null), false);
});

// ---- 統合: mock-device-op.mjs → NdjsonParser → isDeviceOpEvent ----

test("統合: mock-device-op.mjs start-device(成功)は log→log→finished(ok:true) の順で exit 0", async () => {
  const { events, exitCode } = await runMockDeviceOp(["start-device", "--name", "シミュ1"]);
  assert.equal(exitCode, 0);
  assert.deepEqual(
    events.map((e) => e.kind),
    ["log", "log", "finished"],
  );
  assert.equal(events[2].ok, true);
  assert.equal(events[2].error, null);
});

test("統合: mock-device-op.mjs stop-device --fail は log→finished(ok:false) の順で exit 1", async () => {
  const { events, exitCode } = await runMockDeviceOp(["stop-device", "--name", "シミュ2", "--fail"]);
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

test("isMonitorFromWebviewMessage: devicesRestartGpu は非空 devices 配列({name, machine?})のみ受理する", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", devices: [{ name: "A" }] }), true);
  assert.equal(isMonitorFromWebviewMessage(
    { type: "devicesRestartGpu", devices: [{ name: "A" }, { name: "B", machine: "M1Max" }] }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", devices: [] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", devices: [{ name: "A" }, { name: "" }] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", devices: [{ name: "A", machine: "" }] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", devices: ["A"] }), false);
  // 旧形(names)は読まない(同時配布なので両対応にしない)
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu", names: ["A"] }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesRestartGpu" }), false);
});

test("isMonitorFromWebviewMessage: deviceRestartGpu は machine を運ぶ(省略 = 手元、空文字は拒否)", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceRestartGpu", name: "A" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceRestartGpu", name: "A", machine: "M1Max" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceRestartGpu", name: "A", machine: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceRestartGpu", name: "A", machine: 1 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "deviceRestartGpu", name: "" }), false);
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

test("devicesTabVisible: boolean の visible だけ受け付ける", () => {
  // モニター内タブの切替通知(対向: src/webview/monitor/tabs.js)。
  // ホストはこれとパネル自体の表示可否の AND を deviceStream.setVisible へ渡す。
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesTabVisible", visible: true }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesTabVisible", visible: false }), true);
  // visible 欠落・型違いを通すと undefined が false 扱いになり、常に配信が止まりうる
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesTabVisible" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesTabVisible", visible: "true" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "devicesTabVisible", visible: 1 }), false);
});

test("setLptScheduling: boolean の value だけ受け付ける", () => {
  // 設定タブ「スケジューリング」の切替(対向: src/webview/monitor/settingsTab.js)。
  // ホストは fleetest.lptScheduling を更新し、false のとき api run へ --no-lpt を渡す。
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptScheduling", value: true }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptScheduling", value: false }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptScheduling" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptScheduling", value: "true" }), false);
});

test("setRetention: 上限はバイト(0以上の整数)か null・未知の鍵は弾く", () => {
  // 設定タブ「ログ・録画」のクリーンアップ欄(対向: src/webview/monitor/settingsTab.js)。鍵は CLI の JSON と
  // 1文字も同じ。未知の鍵を通すと綴り違いがそのまま CLI へ渡り、黙って無視されて
  // 「打ったのに効かない」になる。
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: 524288000 } }), true);
  // 0 は「保持しない」の有効な指定
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: 0 } }), true);
  // null = その鍵を既定へ戻す(入力欄を空にした・不正値を打った場合)
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: null } }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { sweepAfterRun: false } }), true);
  assert.equal(
    isMonitorFromWebviewMessage({
      type: "setRetention",
      patch: { deviceCapturesMaxBytes: 21474836480, recordingsMaxBytes: null },
    }),
    true,
  );

  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: -1 } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: 1.5 } }), false,
    "バイトは整数(単位変換は webview 側で済ませる)");
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logsMaxBytes: "500" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { sweepAfterRun: 1 } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: { logMaxBytes: 1 } }), false,
    "綴り違いの鍵");
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention", patch: {} }), false, "空の差分は送らない");
  assert.equal(isMonitorFromWebviewMessage({ type: "setRetention" }), false);
});

test("runCleanup: boolean の dryRun だけ受け付ける", () => {
  // dryRun 欠落を通すと undefined が false 扱いになり、見積もりのつもりで本当に消える
  assert.equal(isMonitorFromWebviewMessage({ type: "runCleanup", dryRun: false }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "runCleanup", dryRun: true }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "runCleanup" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "runCleanup", dryRun: "false" }), false);
});

test("setLptHistoryRuns: 1以上の整数か null だけ受け付ける", () => {
  // 0・負値・小数を通すと実績の走査件数が壊れる(CLI 側でも 1 に丸めるが入口で弾く)
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: 20 }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: 1 }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: null }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: 0 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: -1 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: 2.5 }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns", value: "20" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setLptHistoryRuns" }), false);
});
