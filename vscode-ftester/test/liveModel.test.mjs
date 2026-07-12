// liveModel.test.mjs
// liveModel.ts(list-devices の検証、live serve の NDJSON コマンド組み立て/イベント検証、
// 座標変換、要素行フォーマット、CLI引数組み立て、webviewメッセージプロトコル)のユニットテスト。
// node:test で実行する。esbuild が "../src/liveModel"(拡張子なし)を liveModel.ts に解決して
// バンドルする。
//
// 末尾に、test/fixtures/mock-live.mjs を実際に spawn して liveModel の解析関数に通す統合テストと、
// 実バイナリ(.build/debug/ftester。存在すれば)を使った疎通確認テストを含む
// (profileModel.test.mjs / monitorModel.test.mjs と同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import path from "node:path";
import { test } from "node:test";
import {
  buildDeviceArgs,
  buildFallbackDevice,
  devicesToOptions,
  fallbackDeviceOption,
  FALLBACK_DEVICE_ID,
  formatElementLine,
  frameToDisplayRect,
  isLiveFromWebviewMessage,
  isLiveWebviewEnvelope,
  isListDevicesResult,
  parseListAppsResult,
  parseLiveActionResult,
  parseLiveServeEvent,
  parseLiveSnapshotResult,
  parseListDevicesResult,
  pointFromClick,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  toSnapshotMessage,
} from "../src/liveModel";

// ---- isListDevicesResult / parseListDevicesResult ----

test("isListDevicesResult: 正常な値(iOS/Android混在)を true と判定する", () => {
  const value = {
    project: "SampleApp",
    machine: "M1 Max",
    devices: [
      { name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null },
      { name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null },
    ],
  };
  assert.equal(isListDevicesResult(value), true);
  assert.deepEqual(parseListDevicesResult(value), value);
});

test("isListDevicesResult: 接続済みAndroid(serial あり)も true", () => {
  const value = {
    project: "SampleApp",
    machine: "M1 Max",
    devices: [
      { name: "エミュ1", platform: "android", state: "connected", detail: "接続済み", port: null, serial: "emulator-5554" },
    ],
  };
  assert.equal(isListDevicesResult(value), true);
});

test("isListDevicesResult: トップレベルのフィールド欠落/型不一致は false", () => {
  assert.equal(isListDevicesResult(null), false);
  assert.equal(isListDevicesResult("not an object"), false);
  assert.equal(isListDevicesResult({}), false);
  assert.equal(isListDevicesResult({ project: "P", devices: [] }), false); // machine 欠落
  assert.equal(isListDevicesResult({ project: "P", machine: "M", devices: "not-array" }), false);
});

test("isListDevicesResult: devices 要素の platform/state が不正なら false", () => {
  const base = { name: "d", detail: "", port: null, serial: null };
  assert.equal(
    isListDevicesResult({
      project: "P",
      machine: "M",
      devices: [{ ...base, platform: "windows", state: "connected" }],
    }),
    false,
  );
  assert.equal(
    isListDevicesResult({
      project: "P",
      machine: "M",
      devices: [{ ...base, platform: "ios", state: "notBooted" }],
    }),
    false,
    "state の語彙は connected/booted/offline の3値のみ(notBooted は実際の CLI 出力に存在しない)",
  );
});

test("parseListDevicesResult: 不正値は undefined を返す", () => {
  assert.equal(parseListDevicesResult({ foo: "bar" }), undefined);
});

// ---- parseListAppsResult ----

test("parseListAppsResult: 正常な値(user/system混在)を apps 配列として返す", () => {
  const value = {
    platform: "ios",
    apps: [
      { id: "com.example.sampleapp", name: "SampleApp", type: "user" },
      { id: "com.apple.springboard", name: "SpringBoard", type: "system" },
    ],
  };
  assert.deepEqual(parseListAppsResult(value), value.apps);
});

test("parseListAppsResult: apps が配列でない、または要素が不正なら undefined", () => {
  assert.equal(parseListAppsResult({ platform: "ios", apps: "not-array" }), undefined);
  assert.equal(
    parseListAppsResult({ platform: "ios", apps: [{ id: "com.example.app", name: "App", type: "other" }] }),
    undefined,
  );
  assert.equal(
    parseListAppsResult({ platform: "ios", apps: [{ id: "com.example.app", type: "user" }] }),
    undefined,
    "name 欠落は不正",
  );
  assert.equal(parseListAppsResult({ apps: [] }), undefined, "platform 欠落は不正");
  assert.equal(parseListAppsResult(null), undefined);
});

// ---- parseLiveSnapshotResult ----

test("parseLiveSnapshotResult: 成功形(ok:true)をそのまま返す", () => {
  const value = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [
      { ref: 1, type: "Button", label: "ログイン", identifier: null, value: null, frame: { x: 0, y: 0, width: 10, height: 10 } },
    ],
  };
  assert.deepEqual(parseLiveSnapshotResult(value), value);
});

test("parseLiveSnapshotResult: 失敗形(ok:false)をそのまま返す", () => {
  const value = { ok: false, error: "接続できません" };
  assert.deepEqual(parseLiveSnapshotResult(value), value);
});

test("parseLiveSnapshotResult: platform が ios/android 以外なら undefined", () => {
  const value = { ok: true, platform: "windows", screen: { width: 1, height: 1 }, image: "A", elements: [] };
  assert.equal(parseLiveSnapshotResult(value), undefined);
});

test("parseLiveSnapshotResult: elements の frame が欠落していれば undefined", () => {
  const value = {
    ok: true,
    platform: "ios",
    screen: { width: 1, height: 1 },
    image: "A",
    elements: [{ ref: 1, type: "Button", label: null, identifier: null, value: null }],
  };
  assert.equal(parseLiveSnapshotResult(value), undefined);
});

test("parseLiveSnapshotResult: 何にも一致しない値は undefined", () => {
  assert.equal(parseLiveSnapshotResult({ foo: "bar" }), undefined);
  assert.equal(parseLiveSnapshotResult(null), undefined);
});

// ---- parseLiveActionResult ----

test("parseLiveActionResult: {ok:true} を { ok: true } に正規化する", () => {
  assert.deepEqual(parseLiveActionResult({ ok: true }), { ok: true });
});

test("parseLiveActionResult: {ok:false,error} をそのまま返す", () => {
  assert.deepEqual(parseLiveActionResult({ ok: false, error: "失敗しました" }), {
    ok: false,
    error: "失敗しました",
  });
});

test("parseLiveActionResult: ok が欠落/非boolean、または error が非文字列なら undefined", () => {
  assert.equal(parseLiveActionResult({}), undefined);
  assert.equal(parseLiveActionResult({ ok: "true" }), undefined);
  assert.equal(parseLiveActionResult({ ok: false }), undefined);
  assert.equal(parseLiveActionResult({ ok: false, error: 123 }), undefined);
  assert.equal(parseLiveActionResult(null), undefined);
});

// ---- serializeLiveServeCommand ----

test("serializeLiveServeCommand: JSON化して末尾に改行を付ける", () => {
  assert.equal(serializeLiveServeCommand({ cmd: "refresh" }), '{"cmd":"refresh"}\n');
  assert.equal(serializeLiveServeCommand({ cmd: "tap", ref: 3 }), '{"cmd":"tap","ref":3}\n');
  assert.equal(
    serializeLiveServeCommand({ cmd: "tap", x: 1.5, y: 2.5 }),
    '{"cmd":"tap","x":1.5,"y":2.5}\n',
  );
  assert.equal(
    serializeLiveServeCommand({ cmd: "type", text: "hello", ref: null }),
    '{"cmd":"type","text":"hello","ref":null}\n',
  );
  assert.equal(
    serializeLiveServeCommand({ cmd: "swipe", direction: "up" }),
    '{"cmd":"swipe","direction":"up"}\n',
  );
  assert.equal(serializeLiveServeCommand({ cmd: "launch", bundle: "com.example.app" }), '{"cmd":"launch","bundle":"com.example.app"}\n');
  assert.equal(serializeLiveServeCommand({ cmd: "terminate" }), '{"cmd":"terminate"}\n');
  assert.equal(
    serializeLiveServeCommand({ cmd: "install", path: "/tmp/x.app" }),
    '{"cmd":"install","path":"/tmp/x.app"}\n',
  );
});

// ---- parseLiveServeEvent ----

test("parseLiveServeEvent: kind=actionResult の成功/失敗を判別する", () => {
  assert.deepEqual(parseLiveServeEvent({ kind: "actionResult", ok: true }), {
    kind: "actionResult",
    result: { ok: true },
  });
  assert.deepEqual(parseLiveServeEvent({ kind: "actionResult", ok: false, error: "失敗しました" }), {
    kind: "actionResult",
    result: { ok: false, error: "失敗しました" },
  });
});

test("parseLiveServeEvent: kind=snapshot の成功/失敗を判別する", () => {
  const success = {
    kind: "snapshot",
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [],
  };
  assert.deepEqual(parseLiveServeEvent(success), {
    kind: "snapshot",
    result: { ok: true, platform: "ios", screen: { width: 402, height: 874 }, image: "AAAA", elements: [] },
  });
  assert.deepEqual(parseLiveServeEvent({ kind: "snapshot", ok: false, error: "接続できません" }), {
    kind: "snapshot",
    result: { ok: false, error: "接続できません" },
  });
});

test("parseLiveServeEvent: kind=frame の成功/失敗/欠落を判別する", () => {
  assert.deepEqual(parseLiveServeEvent({ kind: "frame", ok: true, image: "abc" }), {
    kind: "frame",
    result: { ok: true, image: "abc" },
  });
  assert.deepEqual(parseLiveServeEvent({ kind: "frame", ok: false, error: "x" }), {
    kind: "frame",
    result: { ok: false, error: "x" },
  });
  assert.equal(
    parseLiveServeEvent({ kind: "frame", ok: true }),
    undefined,
    "image 欠落は frame として不正",
  );
});

test("parseLiveServeEvent: kind が無い/未知、または中身が不正なら undefined", () => {
  assert.equal(parseLiveServeEvent(null), undefined);
  assert.equal(parseLiveServeEvent({}), undefined);
  assert.equal(parseLiveServeEvent({ kind: "unknown", ok: true }), undefined);
  assert.equal(parseLiveServeEvent({ kind: "actionResult" }), undefined, "ok 欠落は actionResult として不正");
  assert.equal(
    parseLiveServeEvent({ kind: "snapshot", ok: true, platform: "windows" }),
    undefined,
    "platform 不正は snapshot として不正",
  );
});

// ---- sameLiveDeviceRef ----

test("sameLiveDeviceRef: platform/port/serial が全て一致すれば true", () => {
  assert.equal(
    sameLiveDeviceRef({ platform: "ios", port: 8127, serial: null }, { platform: "ios", port: 8127, serial: null }),
    true,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "android", port: null, serial: "emulator-5554" },
      { platform: "android", port: null, serial: "emulator-5554" },
    ),
    true,
  );
});

test("sameLiveDeviceRef: platform/port/serial のいずれかが異なれば false", () => {
  assert.equal(
    sameLiveDeviceRef({ platform: "ios", port: 8127, serial: null }, { platform: "android", port: 8127, serial: null }),
    false,
  );
  assert.equal(
    sameLiveDeviceRef({ platform: "ios", port: 8127, serial: null }, { platform: "ios", port: 8128, serial: null }),
    false,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "android", port: null, serial: "emulator-5554" },
      { platform: "android", port: null, serial: "emulator-5556" },
    ),
    false,
  );
});

// ---- pointFromClick ----

test("pointFromClick: 表示pxの中央クリックはスクリーン中央のポイント座標になる", () => {
  const point = pointFromClick({ x: 201, y: 437 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.equal(point.x, 201);
  assert.equal(point.y, 437);
});

test("pointFromClick: 表示サイズがスクリーンより小さい場合も比例変換する", () => {
  // 表示200x434(実機の半分程度)でクリック(100,217) = 表示の中央 → スクリーン中央(201,437)相当
  const point = pointFromClick({ x: 100, y: 217 }, { width: 200, height: 434 }, { width: 402, height: 874 });
  assert.ok(Math.abs(point.x - 201) < 1);
  assert.ok(Math.abs(point.y - 437) < 1);
});

test("pointFromClick: 変換結果はスクリーン範囲にクランプする", () => {
  const point = pointFromClick({ x: 500, y: -10 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.equal(point.x, 402);
  assert.equal(point.y, 0);
});

test("pointFromClick: 表示サイズ/スクリーンサイズが0以下なら (0, 0) を返す", () => {
  assert.deepEqual(pointFromClick({ x: 10, y: 10 }, { width: 0, height: 100 }, { width: 100, height: 100 }), {
    x: 0,
    y: 0,
  });
  assert.deepEqual(pointFromClick({ x: 10, y: 10 }, { width: 100, height: 100 }, { width: 100, height: 0 }), {
    x: 0,
    y: 0,
  });
});

// ---- frameToDisplayRect ----

test("frameToDisplayRect: 表示サイズ=スクリーンサイズなら frame をそのまま返す", () => {
  const rect = frameToDisplayRect({ x: 20, y: 780, width: 362, height: 48 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.deepEqual(rect, { x: 20, y: 780, width: 362, height: 48 });
});

test("frameToDisplayRect: 表示サイズが半分ならスケールも半分になる", () => {
  const rect = frameToDisplayRect({ x: 20, y: 780, width: 362, height: 48 }, { width: 402, height: 874 }, { width: 201, height: 437 });
  assert.equal(rect.x, 10);
  assert.equal(rect.y, 390);
  assert.equal(rect.width, 181);
  assert.equal(rect.height, 24);
});

test("frameToDisplayRect: スクリーンサイズが0以下なら全て0の矩形を返す", () => {
  const rect = frameToDisplayRect({ x: 1, y: 1, width: 1, height: 1 }, { width: 0, height: 0 }, { width: 100, height: 100 });
  assert.deepEqual(rect, { x: 0, y: 0, width: 0, height: 0 });
});

// ---- formatElementLine ----

test("formatElementLine: label/identifier/value が全て揃っている場合", () => {
  const line = formatElementLine({
    ref: 3,
    type: "TextField",
    label: "ユーザー名",
    identifier: "username_field",
    value: "wave1008",
    frame: { x: 0, y: 0, width: 0, height: 0 },
  });
  assert.equal(line, "[3] TextField 「ユーザー名」 id=username_field =wave1008");
});

test("formatElementLine: null/空文字のフィールドは省く", () => {
  const line = formatElementLine({
    ref: 1,
    type: "Button",
    label: "ログイン",
    identifier: null,
    value: "",
    frame: { x: 0, y: 0, width: 0, height: 0 },
  });
  assert.equal(line, "[1] Button 「ログイン」");
});

test("formatElementLine: label/identifier/value 全て無ければ [ref] type だけ", () => {
  const line = formatElementLine({
    ref: 5,
    type: "Image",
    label: null,
    identifier: null,
    value: null,
    frame: { x: 0, y: 0, width: 0, height: 0 },
  });
  assert.equal(line, "[5] Image");
});

// ---- buildDeviceArgs ----

test("buildDeviceArgs: iOS + port あり", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: 8127, serial: null }), [
    "--platform",
    "ios",
    "--port",
    "8127",
  ]);
});

test("buildDeviceArgs: iOS + port 無し(null/0以下)は --port を付けない", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: null, serial: null }), ["--platform", "ios"]);
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: 0, serial: null }), ["--platform", "ios"]);
});

test("buildDeviceArgs: Android + serial あり", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: "emulator-5554" }), [
    "--platform",
    "android",
    "--serial",
    "emulator-5554",
  ]);
});

test("buildDeviceArgs: Android + serial 無し(null/空文字)は --serial を付けない", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: null }), ["--platform", "android"]);
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: "  " }), ["--platform", "android"]);
});

// ---- buildFallbackDevice / fallbackDeviceOption ----

test("buildFallbackDevice: port=0/serial=\"\" は未指定(null)として扱う", () => {
  assert.deepEqual(buildFallbackDevice({ platform: "ios", port: 0, serial: "" }), {
    platform: "ios",
    port: null,
    serial: null,
  });
});

test("buildFallbackDevice: port>0/serial非空はそのまま(trim済み)使う", () => {
  assert.deepEqual(buildFallbackDevice({ platform: "android", port: 0, serial: "  emulator-5554  " }), {
    platform: "android",
    port: null,
    serial: "emulator-5554",
  });
});

test("fallbackDeviceOption: id=FALLBACK_DEVICE_ID・state=unknown で組み立てる", () => {
  const option = fallbackDeviceOption({ platform: "ios", port: 8100, serial: "" });
  assert.equal(option.id, FALLBACK_DEVICE_ID);
  assert.equal(option.name, "設定のデバイス");
  assert.equal(option.platform, "ios");
  assert.equal(option.state, "unknown");
  assert.equal(option.port, 8100);
  assert.equal(option.serial, null);
});

// ---- devicesToOptions ----

test("devicesToOptions: platform:name の id を付けて変換する", () => {
  const options = devicesToOptions([
    { name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null },
    { name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null },
  ]);
  assert.equal(options.length, 2);
  assert.equal(options[0].id, "ios:シミュ1");
  assert.equal(options[0].state, "connected");
  assert.equal(options[1].id, "android:エミュ1");
  assert.equal(options[1].state, "offline");
});

// ---- toSnapshotMessage ----

test("toSnapshotMessage: elements に formatElementLine と同じ line フィールドを付与する", () => {
  const snapshot = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [
      {
        ref: 1,
        type: "Button",
        label: "ログイン",
        identifier: "login_button",
        value: null,
        frame: { x: 20, y: 780, width: 362, height: 48 },
      },
    ],
  };
  const message = toSnapshotMessage(snapshot);
  assert.equal(message.type, "snapshot");
  assert.equal(message.platform, "ios");
  assert.deepEqual(message.screen, { width: 402, height: 874 });
  assert.equal(message.image, "AAAA");
  assert.equal(message.elements.length, 1);
  assert.equal(message.elements[0].line, formatElementLine(snapshot.elements[0]));
  assert.equal(message.elements[0].line, "[1] Button 「ログイン」 id=login_button");
  // 元の frame 情報も保持していること(ホバー枠オーバーレイに必要)
  assert.deepEqual(message.elements[0].frame, { x: 20, y: 780, width: 362, height: 48 });
});

// ---- isLiveFromWebviewMessage ----

test("isLiveFromWebviewMessage: 各メッセージ種別の正常な値を true と判定する", () => {
  assert.equal(isLiveFromWebviewMessage({ type: "refreshDevices" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "refreshSnapshot" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "terminate" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "selectDevice", id: "ios:シミュ1" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "openDevice", id: "ios:iPhone 17 Pro" }), true);
  assert.equal(
    isLiveFromWebviewMessage({ type: "tapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }),
    true,
  );
  assert.equal(
    isLiveFromWebviewMessage({
      type: "pressPoint",
      clickX: 1,
      clickY: 2,
      displayWidth: 3,
      displayHeight: 4,
      holdMs: 500,
    }),
    true,
  );
  assert.equal(
    isLiveFromWebviewMessage({
      type: "dragPoints",
      fromX: 1,
      fromY: 2,
      toX: 3,
      toY: 4,
      displayWidth: 5,
      displayHeight: 6,
      pressMs: 50,
      dragMs: 200,
    }),
    true,
  );
  assert.equal(isLiveFromWebviewMessage({ type: "tapRef", ref: 1 }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "swipe", direction: "up" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "typeText", text: "hello", ref: null }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "typeText", text: "hello", ref: 2 }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "launch", bundleId: "com.example.app" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "activate", bundleId: "com.example.sampleapp" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "appSwitcher" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "install", path: "/tmp/x.app" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "pickInstallFile", platform: "ios" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "pickInstallFile", platform: "android" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "refreshApps" }), true);
  assert.equal(isLiveFromWebviewMessage({ type: "visibility", visible: true }), true);
});

test("isLiveFromWebviewMessage: 未知の type・型不一致・フィールド欠落は false", () => {
  assert.equal(isLiveFromWebviewMessage(null), false);
  assert.equal(isLiveFromWebviewMessage("refreshDevices"), false);
  assert.equal(isLiveFromWebviewMessage({}), false);
  assert.equal(isLiveFromWebviewMessage({ type: "unknown" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "selectDevice" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "openDevice" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "swipe", direction: "diagonal" }), false);
  assert.equal(
    isLiveFromWebviewMessage({ type: "dragPoints", fromX: 1, fromY: 2, toX: 3, displayWidth: 5, displayHeight: 6 }),
    false,
    "toY 欠落は不正",
  );
  assert.equal(
    isLiveFromWebviewMessage({
      type: "dragPoints",
      fromX: 1,
      fromY: 2,
      toX: 3,
      toY: 4,
      displayWidth: 5,
      displayHeight: 6,
      pressMs: 50,
    }),
    false,
    "dragMs 欠落は不正",
  );
  assert.equal(
    isLiveFromWebviewMessage({ type: "pressPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }),
    false,
    "holdMs 欠落は不正",
  );
  assert.equal(isLiveFromWebviewMessage({ type: "tapRef", ref: "1" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "typeText", text: 1, ref: null }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "activate" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "pickInstallFile", platform: "windows" }), false);
  assert.equal(isLiveFromWebviewMessage({ type: "visibility" }), false);
});

// ---- isLiveWebviewEnvelope ----

test("isLiveWebviewEnvelope: type:'live' + 正常な LiveFromWebviewMessage を true と判定する", () => {
  assert.equal(isLiveWebviewEnvelope({ type: "live", message: { type: "refreshDevices" } }), true);
  assert.equal(
    isLiveWebviewEnvelope({ type: "live", message: { type: "tapRef", ref: 3 } }),
    true,
  );
});

test("isLiveWebviewEnvelope: type が 'live' 以外、または message が不正なら false", () => {
  assert.equal(isLiveWebviewEnvelope({ type: "monitor", message: { type: "refreshDevices" } }), false);
  assert.equal(isLiveWebviewEnvelope({ type: "live", message: { type: "unknown" } }), false);
  assert.equal(isLiveWebviewEnvelope({ type: "live" }), false);
  assert.equal(isLiveWebviewEnvelope(null), false);
  assert.equal(isLiveWebviewEnvelope({}), false);
});

// ---- 統合: mock-live.mjs を実際に spawn して liveModel の解析関数に通す ----

const MOCK_LIVE = path.resolve(process.cwd(), "test", "fixtures", "mock-live.mjs");

/** mock-live.mjs list-devices をワンショット spawn し、livePanel.ts の runOneShot() 相当の挙動
 * (stdout 全体を JSON.parse)を再現して { json, exitCode } を返す。 */
function runMockListDevices(args) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_LIVE, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    proc.stdout.on("data", (chunk) => chunks.push(chunk));
    proc.on("error", reject);
    proc.on("close", (exitCode) => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      let json;
      if (text.length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          json = undefined;
        }
      }
      resolve({ json, exitCode });
    });
  });
}

/**
 * mock-live.mjs live serve(または実バイナリの `api live serve`)を常駐 spawn し、
 * livePanel.ts の sendServeCommand() 相当の挙動(コマンド送信 → NDJSON 行を指定数だけ読む)を
 * 再現するテストダブル。send() は生の JSON.parse 値の配列を返す(parseLiveServeEvent への
 * 通し方はテスト側に委ねる)。close() は stdin を閉じてプロセスの終了(exitCode)を待つ。
 */
function spawnServe(binaryPath, args, cwd) {
  const proc = spawn(binaryPath, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
  const rl = createInterface({ input: proc.stdout, terminal: false });
  const lineQueue = [];
  const waiters = [];
  rl.on("line", (line) => {
    let value;
    try {
      value = JSON.parse(line);
    } catch {
      return;
    }
    const waiter = waiters.shift();
    if (waiter) {
      waiter(value);
    } else {
      lineQueue.push(value);
    }
  });

  function nextLine() {
    const queued = lineQueue.shift();
    if (queued !== undefined) {
      return Promise.resolve(queued);
    }
    return new Promise((resolve) => waiters.push(resolve));
  }

  return {
    async send(command, expectLines) {
      proc.stdin.write(`${JSON.stringify(command)}\n`);
      const lines = [];
      for (let i = 0; i < expectLines; i += 1) {
        lines.push(await nextLine());
      }
      return lines;
    },
    close() {
      return new Promise((resolve) => {
        proc.once("close", (exitCode) => resolve(exitCode));
        proc.stdin.end();
      });
    },
  };
}

test("統合: mock-live.mjs list-devices の成功出力を parseListDevicesResult に通せる", async () => {
  const { json, exitCode } = await runMockListDevices(["list-devices", "--project", "SampleApp"]);
  assert.equal(exitCode, 0);
  const parsed = parseListDevicesResult(json);
  assert.ok(parsed, "解析できること");
  assert.equal(parsed.project, "SampleApp");
  assert.equal(parsed.devices.length, 2);
  assert.equal(parsed.devices[0].state, "connected");
  assert.equal(parsed.devices[1].state, "offline");
});

test("統合: mock-live.mjs list-devices --project NoMachine は非0終了・stdout無しで parseListDevicesResult が undefined を返す", async () => {
  const { json, exitCode } = await runMockListDevices(["list-devices", "--project", "NoMachine"]);
  assert.equal(exitCode, 1);
  assert.equal(json, undefined);
  assert.equal(parseListDevicesResult(json), undefined);
});

test("統合: mock-live.mjs live serve の refresh は snapshot イベント1行だけを返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [line] = await serve.send({ cmd: "refresh" }, 1);
  const event = parseLiveServeEvent(line);
  assert.ok(event && event.kind === "snapshot" && event.result.ok, "snapshot が成功として解析できること");
  assert.equal(event.result.screen.width, 402);
  assert.equal(event.result.elements.length, 2);
  const message = toSnapshotMessage(event.result);
  assert.equal(message.elements[0].line, "[1] Button 「ログイン」 id=login_button");
  const exitCode = await serve.close();
  assert.equal(exitCode, 0, "stdin EOF でクリーンに終了すること");
});

test("統合: mock-live.mjs live serve の tap は actionResult(ok:true) → snapshot の2行を返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [actionLine, snapshotLine] = await serve.send({ cmd: "tap", ref: 1 }, 2);
  const actionEvent = parseLiveServeEvent(actionLine);
  assert.deepEqual(actionEvent, { kind: "actionResult", result: { ok: true } });
  const snapshotEvent = parseLiveServeEvent(snapshotLine);
  assert.ok(snapshotEvent && snapshotEvent.kind === "snapshot" && snapshotEvent.result.ok);
  await serve.close();
});

test("統合: mock-live.mjs live serve の tap --ref 999 は actionResult(ok:false) を返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [actionLine] = await serve.send({ cmd: "tap", ref: 999 }, 1);
  const actionEvent = parseLiveServeEvent(actionLine);
  assert.ok(actionEvent && actionEvent.kind === "actionResult" && actionEvent.result.ok === false);
  assert.ok(actionEvent.result.error.includes("tap"));
  await serve.close();
});

test("統合: mock-live.mjs live serve --fail-all は snapshot も ok:false を返す(常駐プロセスの継続的な異常を再現)", async () => {
  const serve = spawnServe(
    process.execPath,
    [MOCK_LIVE, "live", "serve", "--platform", "ios", "--fail-all"],
    process.cwd(),
  );
  const [line] = await serve.send({ cmd: "refresh" }, 1);
  const event = parseLiveServeEvent(line);
  assert.ok(event && event.kind === "snapshot" && event.result.ok === false);
  await serve.close();
});

// ---- 実バイナリ(存在すれば): api live serve ----

// npm test は vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上(profileModel.test.mjs と同じ)。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const BINARY_PATH = path.join(REPO_ROOT, ".build", "debug", "ftester");
const BINARY_EXISTS = existsSync(BINARY_PATH);

test(
  "実バイナリ(存在すれば): `ftester api live serve --platform ios --port 9999` はデバイス無しでも refresh に ok:false で応答し、stdin EOF でクリーンに終了する",
  { skip: !BINARY_EXISTS && "実バイナリ(.build/debug/ftester)が見つからないため skip します" },
  async () => {
    const serve = spawnServe(
      BINARY_PATH,
      ["api", "live", "serve", "--platform", "ios", "--port", "9999"],
      REPO_ROOT,
    );
    const [line] = await serve.send({ cmd: "refresh" }, 1);
    const event = parseLiveServeEvent(line);
    assert.ok(
      event && event.kind === "snapshot" && event.result.ok === false,
      `ok:false の snapshot として解析できること: ${JSON.stringify(line)}`,
    );
    assert.ok(event.result.error.length > 0);

    const exitCode = await serve.close();
    assert.equal(exitCode, 0, "接続失敗しても常駐は継続し、stdin EOF でクリーンに(exit 0 で)終了すること");
  },
);
