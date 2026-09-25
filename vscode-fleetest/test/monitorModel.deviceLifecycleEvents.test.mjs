// monitorModel.deviceLifecycleEvents.test.mjs
// monitorModel.ts のうち、デバイスカタログ/インストール済み一覧の JSON 検証
// (isDeviceCatalogJson/isInstalledDevicesJson)、デバイス作成・システムイメージ導入・削除の
// NDJSON イベント検証(isCreateDeviceEvent/isInstallSystemImageEvent/
// installSystemImageApiArgs/deleteDeviceApiArgs/isDeleteDeviceEvent)、restartBatch
// (GPU 一括再起動)・devicesUp の restartNames 統合・起動中断まわりの DeviceLifecycleQueue
// テストを扱う。node:test で実行する。monitorModel.test.mjs から分割。
//
// 末尾に、mock-monitor.mjs / mock-device-op.mjs を実際に spawn して NdjsonParser →
// monitorModel に通す統合テストを含む(monitorPanel.ts の配線を再現する。
// runReducer.test.mjs の mock-runner.mjs 統合テストと同じ方針)。esbuild が
// "../src/monitorModel"(拡張子なし)を monitorModel.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  bulkLifecycleOp,
  createDeviceLifecycleQueueState,
  deleteDeviceApiArgs,
  deviceLifecycleJobNeedsMonitorPause,
  deviceLifecycleStatusFor,
  enqueueDeviceLifecycleJob,
  hasDeviceLifecycleJobFor,
  installSystemImageApiArgs,
  isCreateDeviceEvent,
  isDeleteDeviceEvent,
  isDeviceCatalogJson,
  isDeviceOpEvent,
  isDevicesRestartEvent,
  isDevicesUpEvent,
  isInstallSystemImageEvent,
  isInstalledDevicesJson,
  isMonitorEvent,
  isMonitorFromWebviewMessage,
  promoteDeviceLifecycleJobs,
  removeQueuedBulkUpJob,
  removeQueuedDeviceUpJob,
  devicesToWebviewMessage,
  toWebviewMessage,
} from "../src/monitorModel";

// esbuild がこのテストを out-test/ にバンドルするため、import.meta.url はバンドル後の
// 場所を指す。npm test は常に vscode-fleetest/ を cwd として実行されるので、
// process.cwd() を基準に test/fixtures/ を解決する(runReducer.test.mjs と同じ理由)。
const MOCK_MONITOR = path.resolve(process.cwd(), "test", "fixtures", "mock-monitor.mjs");
const MOCK_DEVICE_OP = path.resolve(process.cwd(), "test", "fixtures", "mock-device-op.mjs");

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
        messages.push(value.kind === "monitorDevices"
          ? devicesToWebviewMessage(value.devices, "all")
          : toWebviewMessage(value));
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
  assert.equal(
    isMonitorFromWebviewMessage({ type: "setRetention", patch: { xcresultMaxBytes: 5368709120 } }),
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

test("removeQueuedDeviceUpJob: (machine, name) が一致する待機中の up だけを外し、実行中・別の機械・down は触らない", () => {
  const runningUp = { kind: "device", name: "A", op: "up" };
  const state = {
    running: [runningUp],
    jobs: [
      { kind: "device", name: "A", op: "down" },
      { kind: "device", name: "A", op: "up", machine: "M1Max" },
      { kind: "device", name: "A", op: "up" },
    ],
  };
  const result = removeQueuedDeviceUpJob(state, "A", undefined);
  assert.deepEqual(result.removed, { kind: "device", name: "A", op: "up" });
  assert.deepEqual(result.state.running, [runningUp]);
  assert.equal(result.state.jobs.length, 2);
  assert.equal(removeQueuedDeviceUpJob(state, "B", undefined).removed, undefined);
});

// デバイスの並び順は **手元が先 → 機械名順 → ios→android → name 順**
// (ユーザー決定 2026-09-22。それまではプラットフォームが外側だった)。ここを変えると
// タイル・拡大表示・実行ログ・run ボードのツリーの並びが**全部**変わる(整列はここ1箇所)。
test("デバイスの並びは機械が外側・OS が内側", async () => {
  const { sortMonitorDevices } = await import("../src/monitorDeviceModel");
  const device = (machine, platform, name) => ({
    id: `${machine}:${name}`, name, platform, state: "connected", detail: "", kind: "virtual",
    ...(machine ? { machine } : {}),
  });
  const sorted = sortMonitorDevices([
    device("M1Max", "ios", "iPhone-01"),
    device(undefined, "android", "Pixel-01"),
    device("M1Max", "android", "Pixel-02"),
    device(undefined, "ios", "iPhone-02"),
    device("M1Max", "ios", "iPhone-00"),
  ]);
  assert.deepEqual(sorted.map((d) => d.id), [
    // 手元(machine 無し)が先。その中で ios → android
    "undefined:iPhone-02",
    "undefined:Pixel-01",
    // 続いて機械名順。その中で ios → android、同じ OS では name 順
    "M1Max:iPhone-00",
    "M1Max:iPhone-01",
    "M1Max:Pixel-02",
  ]);
});
