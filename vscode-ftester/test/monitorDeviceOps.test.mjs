// monitorDeviceOps.test.mjs
// MonitorDeviceOps(src/monitorDeviceOps.ts)のライフサイクルキュー実行タイミングの回帰テスト。
// node:test。esbuild が "../src/monitorDeviceOps" を .ts に解決してバンドルする
// (monitorBridgeWatchdog.test.mjs と同じ fake-deps パターン)。
//
// 検証対象: down系ジョブが実行開始する瞬間(spawn直前)に deps.stopDeviceStreams/stopAllStreams
// を呼び、モニタータイルのストリームを即座に破棄する契約(monitorDeviceStreamController.ts の
// disposeForDeviceName/disposeAllForDown と対)。up系では呼ばれないことも確認する。
//
// config.binaryPath には実プロセスが要る(MonitorDeviceOps は spawn を直接呼ぶ)。stdout/NDJSON の
// 内容はここでの検証対象外なので、即終了するだけのダミー実行ファイルで代用する。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorDeviceOps } from "../src/monitorDeviceOps";

/** dirname(binaryPath) に、引数を無視して即 exit 0 するだけの mock ftester を置く。 */
function makeMockBinary() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-deviceops-test-"));
  const binaryPath = path.join(dir, "ftester");
  fs.writeFileSync(binaryPath, "#!/bin/sh\nexit 0\n");
  fs.chmodSync(binaryPath, 0o755);
  return { dir, binaryPath };
}

/** MonitorDeviceOps に渡す最小 fake deps。stopDeviceStreams/stopAllStreams の呼び出しを記録する。 */
function makeDeps(binaryPath) {
  const stopDeviceStreamsCalls = [];
  const stopAllStreamsCalls = [];
  const deps = {
    workspaceRoot: "/tmp",
    getConfig: () => ({ binaryPath, project: "P", profile: "" }),
    outputChannel: { appendLine() {} },
    post: () => {},
    writeMonitorControl: () => {},
    notifyMachineProfilesChanged: () => {},
    stopDeviceStreams: (name) => stopDeviceStreamsCalls.push(name),
    stopAllStreams: () => stopAllStreamsCalls.push(true),
  };
  return { deps, stopDeviceStreamsCalls, stopAllStreamsCalls };
}

/** キューが空になるまで待つ(スポーンした mock プロセスの close を待機、テスト間の後始末用)。 */
async function waitUntilIdle(deviceOps, timeoutMs = 3000) {
  const start = Date.now();
  while (deviceOps.isQueueBusy()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("ライフサイクルキューが時間内に空になりませんでした");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("device-down ジョブは実行開始時に stopDeviceStreams(name) を同期的に呼ぶ(stopAllStreamsは呼ばない)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, stopDeviceStreamsCalls, stopAllStreamsCalls } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "down" });
    // enqueueLifecycleJob は空キューなら即 runLifecycleQueueHead() を呼ぶため、spawn 前の
    // フック呼び出しはこの時点で既に観測できる。
    assert.deepEqual(stopDeviceStreamsCalls, ["シミュ1"]);
    assert.deepEqual(stopAllStreamsCalls, []);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("device-up ジョブは stopDeviceStreams/stopAllStreams のどちらも呼ばない", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, stopDeviceStreamsCalls, stopAllStreamsCalls } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "up" });
    assert.deepEqual(stopDeviceStreamsCalls, []);
    assert.deepEqual(stopAllStreamsCalls, []);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("bulk down ジョブは実行開始時に stopAllStreams を呼ぶ(stopDeviceStreamsは呼ばない)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, stopDeviceStreamsCalls, stopAllStreamsCalls } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "down" });
    assert.deepEqual(stopAllStreamsCalls, [true]);
    assert.deepEqual(stopDeviceStreamsCalls, []);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("bulk up ジョブは stopDeviceStreams/stopAllStreams のどちらも呼ばない", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, stopDeviceStreamsCalls, stopAllStreamsCalls } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "up" });
    assert.deepEqual(stopAllStreamsCalls, []);
    assert.deepEqual(stopDeviceStreamsCalls, []);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---- syncCpuRenderNames(CPU 描画フォールバック記憶と実測 renderMode の同期) ----
// 記憶(cpuRenderNames)は private なので、bulk up の spawn 引数に `--cpu-render <name>` が
// 載るかどうかで観測する(executeBulkJob の引数組み立てがそのまま契約)。

/** 引数を args.log へ追記してから exit 0 する mock ftester。 */
function makeArgRecordingBinary() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-deviceops-args-test-"));
  const binaryPath = path.join(dir, "ftester");
  const argsLog = path.join(dir, "args.log");
  fs.writeFileSync(binaryPath, `#!/bin/sh\necho "$@" >> ${JSON.stringify(argsLog)}\nexit 0\n`);
  fs.chmodSync(binaryPath, 0o755);
  return { dir, binaryPath, argsLog };
}

/** bulk up を1件流し、mock が記録した引数行を返す。 */
async function runBulkUpAndReadArgs(deviceOps, argsLog) {
  deviceOps.enqueueLifecycleJob({ kind: "bulk", op: "up", restartNames: [] });
  await waitUntilIdle(deviceOps);
  return fs.existsSync(argsLog) ? fs.readFileSync(argsLog, "utf8") : "";
}

function androidDevice(name, renderMode, state = "connected") {
  return { id: name, name, platform: "android", state, renderMode };
}

test("syncCpuRenderNames: connected で renderMode が cpu 以外なら記憶を落とす(run 側 GPU 復帰の反映)", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  deviceOps.markCpuRender("Pixel1");
  assert.match(await runBulkUpAndReadArgs(deviceOps, argsLog), /--cpu-render Pixel1/);

  fs.rmSync(argsLog);
  deviceOps.syncCpuRenderNames([androidDevice("Pixel1", "gpu")]);
  assert.doesNotMatch(await runBulkUpAndReadArgs(deviceOps, argsLog), /--cpu-render/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("syncCpuRenderNames: renderMode が cpu / 未受信 / connected 以外 / 非 android なら記憶を保持する", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  deviceOps.markCpuRender("Pixel1");
  deviceOps.syncCpuRenderNames([
    androidDevice("Pixel1", "cpu"),
    androidDevice("Pixel1", undefined),
    androidDevice("Pixel1", "gpu", "booted"),
    { id: "iOS", name: "Pixel1", platform: "ios", state: "connected", renderMode: "gpu" },
  ]);
  assert.match(await runBulkUpAndReadArgs(deviceOps, argsLog), /--cpu-render Pixel1/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("syncCpuRenderNames: ライフサイクルジョブ進行中の個体は落とさない(フォールバック直後の競合対策)", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  // watchdog の CPU フォールバックと同じ順序: markCpuRender → enqueueRestart。再起動が始まるまでの
  // 数秒はまだ「GPU で connected」なので、ここで落とすとフォールバックが永久に発動しない。
  deviceOps.markCpuRender("Pixel1");
  deviceOps.enqueueRestart("Pixel1");
  deviceOps.syncCpuRenderNames([androidDevice("Pixel1", "gpu")]);
  await waitUntilIdle(deviceOps);

  fs.rmSync(argsLog, { force: true });
  assert.match(await runBulkUpAndReadArgs(deviceOps, argsLog), /--cpu-render Pixel1/);
  fs.rmSync(dir, { recursive: true, force: true });
});
