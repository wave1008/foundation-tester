// monitorModel.test.mjs
// monitorModel.ts(isMonitorEvent/toWebviewMessage/isMonitorFromWebviewMessage)のユニットテスト。
// node:test で実行する。esbuild が "../src/monitorModel"(拡張子なし)を monitorModel.ts に
// 解決してバンドルする。
//
// デバイス状態/NDJSON イベントの型ガード、DeviceLifecycleQueue のスケジューラ純粋ロジック、
// 実行/アプリプロファイル名の検証を扱う。実行プロファイル/アプリプロファイルのフォーム
// (parse/update)は monitorModel.profileForms.test.mjs、デバイスカタログ・作成/インストール/
// 削除イベントと mock プロセス統合テストは monitorModel.deviceLifecycleEvents.test.mjs に
// 分割してある。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
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
  disabledMachineSet,
  hasDeviceLifecycleJobFor,
  isDeviceLifecycleQueueBusy,
  isDeviceOpEvent,
  isDevicesUpEvent,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  monitorControlLine,
  RUNNING_DEVICES_PROFILE_VALUE,
  devicesToWebviewMessage,
  toWebviewMessage,
  validateNewAppProfileName,
  validateNewProjectName,
  validateNewRunProfileName,
} from "../src/monitorModel";

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
// 回にタイルの絵が消える(FTAndroid/AndroidBridge.swift の bridgeRunningVerdict と同じ規律)。
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

// 台の一覧だけは toWebviewMessage を通さない —— 表示フィルタ(「起動中のデバイス」)を
// **畳まずに** filter を添えて送り、落とすのは webview の入口(run ボードのツリーは通さない。
// docs/design.md §18.5)。toWebviewMessage 側は Exclude してあるので通し忘れはコンパイルで止まる。
test("devicesToWebviewMessage: 一覧は絞らず filter を添える", () => {
  const devices = [
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "offline", detail: "未起動" },
  ];
  assert.deepEqual(devicesToWebviewMessage(devices, "running"), {
    type: "devices",
    devices,
    filter: "running",
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

test("isMonitorFromWebviewMessage: recordingsExport は project/runID(共に非空文字列)が揃っていれば true", () => {
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport", project: "p", runID: "r" }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport", project: "p", runID: "" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport", project: "", runID: "r" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport", project: "p" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport", runID: "r" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "recordingsExport" }), false);
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

// 他の機械のタイルは開くのに要る属性を remote で運ぶ(LiveTabHost.openForDevice → registerRemoteDevice)
test("isMonitorFromWebviewMessage: openLiveForDevice の remote は機械名・名前・platform・state・kind が揃うときだけ通す", () => {
  const remote = { machine: "M1Ultra", name: "iPhone wave", platform: "ios", state: "connected", kind: "physical", udid: "U" };
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "ios:M1Ultra/iPhone wave", remote }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "x", remote: { ...remote, machine: "" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "x", remote: { ...remote, platform: "tvos" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "x", remote: { ...remote, state: "weird" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "x", remote: { ...remote, udid: 1 } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "openLiveForDevice", id: "x", remote: "M1Ultra" }), false);
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

test("disabledMachineSet: enabled:false の機械と local.enabled:false の手元だけ・欠落は有効", () => {
  assert.deepEqual([...disabledMachineSet(
    [{ machine: "A", enabled: false }, { machine: "B", enabled: true }, { machine: "C" }],
    { enabled: false })].sort(), ["A", "local"]);
  assert.equal(disabledMachineSet([{ machine: "A" }], undefined).size, 0);
});

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
    fmTextOcclusionCheck: true,
    ocrTextOcclusionCheck: true,
    preferCheckStateClassifier: true,
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
    fmTextOcclusionCheck: true,
    ocrTextOcclusionCheck: true,
    preferCheckStateClassifier: true,
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

