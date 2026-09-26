// monitorModel.profileForms.test.mjs
// monitorModel.ts のうち、実行プロファイル/アプリプロファイルのフォーム変換
// (parseRunProfileForForm/parseAppProfileForForm/updateRunProfileInObject/
// updateAppProfileInObject)と、それに関わる webview メッセージ検証(runProfileLoad/Save・
// appProfileLoad/Save・プロファイル管理)、デバイス参照まわりのヘルパー
// (machineDeviceDetail/validateNewDeviceName/removeDeviceFromRunProfile/
// runProfileDeviceRefKey/orderedDeviceEntry/addDevicesToRunProfile)のユニットテスト。
// node:test で実行する。monitorModel.test.mjs から分割。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addDevicesToRunProfile,
  isMonitorFromWebviewMessage,
  machineDeviceDetail,
  orderedDeviceEntry,
  parseAppProfileForForm,
  parseRunProfileForForm,
  removeDeviceFromRunProfile,
  runProfileDeviceRefKey,
  updateAppProfileInObject,
  updateRunProfileInObject,
  validateNewDeviceName,
} from "../src/monitorModel";

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
    fmTextOcclusionCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextOcclusionCheck: true,
    preferCheckStateClassifier: true,
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

test("isMonitorFromWebviewMessage: runProfileSave は profile 非空・fields22項目の型が揃っていれば true", () => {
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
        fmTextOcclusionCheck: false,
        screenLooksLike: false,
        containerInference: false,
        ocrTextOcclusionCheck: false,
        preferCheckStateClassifier: false,
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
      fields: { ...VALID_RUN_PROFILE_SAVE.fields, fmTextOcclusionCheck: "true" }, // boolean でない
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
    fmTextOcclusionCheck: false,
    screenLooksLike: false,
    containerInference: false,
    ocrTextOcclusionCheck: false,
    preferCheckStateClassifier: false,
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
    fmTextOcclusionCheck: false,
    screenLooksLike: false,
    containerInference: false,
    ocrTextOcclusionCheck: false,
    preferCheckStateClassifier: false,
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

test("parseRunProfileForForm: 欠落キーは既定値(app/reportDir/locale/recordBitrateKbps/workspace=''、devices=[]、heal/screenLooksLike/fmTextOcclusionCheck/containerInference=true、iosInappEngine=true、wipeDataOnBloat=true、wipeDataThresholdGB=''、record/recordFailuresOnly/recordFullResolution/iosFastInput/enableAnimations/recoverCpuFallbackToGpu=false、iosPreActionWarmup=true)", () => {
  const parsed = parseRunProfileForForm({});
  assert.deepEqual(parsed, {
    app: "",
    devices: [],
    heal: true,
    fmTextOcclusionCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextOcclusionCheck: true,
    preferCheckStateClassifier: true,
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
    fmTextOcclusionCheck: "false",
    screenLooksLike: "false",
    containerInference: "false",
    ocrTextOcclusionCheck: "true",
    preferCheckStateClassifier: "true",
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
    fmTextOcclusionCheck: true,
    screenLooksLike: true,
    containerInference: true,
    ocrTextOcclusionCheck: true,
    preferCheckStateClassifier: true,
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

test("旧キーは読まず、保存でも特別扱いしない(未公開のツールなので移行処理を置かない)", () => {
  // 改名前の screenIs は読まない = 新キーが無ければ既定 true
  assert.equal(parseRunProfileForForm({ screenIs: false }).screenLooksLike, true);
  // 撤去したキー(screenIs / fm / ocr / triage)も他の未知のキーと同じく引き継ぐだけ
  // (CLI の validate が unknown key として警告する)
  const saved = updateRunProfileInObject(
    { screenIs: false, fm: true, triage: true, app: "a" },
    { ...BASE_RUN_PROFILE_FIELDS, screenLooksLike: true });
  assert.equal(saved.ok, true);
  assert.equal(saved.object.screenLooksLike, true);
  assert.equal(saved.object.screenIs, false);
  assert.equal(saved.object.fm, true);
  assert.equal(saved.object.triage, true);
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
// (RunProfile.swift の `runDoc.fmTextOcclusionCheck ?? true`)と JSON スキーマと3箇所で一致させる
test("parseRunProfileForForm: fmTextOcclusionCheck は boolean ならそのまま返し、欠落/非 boolean は既定値 true", () => {
  assert.equal(parseRunProfileForForm({ fmTextOcclusionCheck: true }).fmTextOcclusionCheck, true);
  assert.equal(parseRunProfileForForm({ fmTextOcclusionCheck: false }).fmTextOcclusionCheck, false);
  assert.equal(parseRunProfileForForm({}).fmTextOcclusionCheck, true);
  assert.equal(parseRunProfileForForm({ fmTextOcclusionCheck: "true" }).fmTextOcclusionCheck, true);
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
  fmTextOcclusionCheck: true,
  screenLooksLike: true,
  containerInference: true,
  ocrTextOcclusionCheck: true,
  preferCheckStateClassifier: true,
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

test("updateRunProfileInObject: 基本更新(app/heal/fmTextOcclusionCheck/screenLooksLike/containerInference/iosInappEngine/wipeDataOnBloat/reportDir)", () => {
  const result = updateRunProfileInObject({ app: "old", devices: [], heal: false, reportDir: "old" }, BASE_RUN_PROFILE_FIELDS);
  assert.equal(result.ok, true);
  assert.equal(result.object.app, "sampleapp");
  assert.equal(result.object.heal, false);
  assert.equal(result.object.fmTextOcclusionCheck, true);
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

test("updateRunProfileInObject: heal/fmTextOcclusionCheck/screenLooksLike/containerInference は true/false どちらも常時書き込む(キー削除しない)", () => {
  for (const key of ["heal", "fmTextOcclusionCheck", "screenLooksLike", "containerInference"]) {
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

