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
import { MonitorDeviceOps, firstLine, signingGuidance, stderrDetailLine } from "../src/monitorDeviceOps";

/** dirname(binaryPath) に、引数を argv ファイルへ落として即 exit 0 する mock fleetest を置く。 */
function makeMockBinary() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-test-"));
  const binaryPath = path.join(dir, "fleetest");
  fs.writeFileSync(binaryPath, `#!/bin/sh\necho "$@" >> "${path.join(dir, "argv")}"\nexit 0\n`);
  fs.chmodSync(binaryPath, 0o755);
  return { dir, binaryPath };
}

function argvLines(dir) {
  const file = path.join(dir, "argv");
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n") : [];
}

/** MonitorDeviceOps に渡す最小 fake deps。stopDeviceStreams/stopAllStreams の呼び出しを記録する。 */
function makeDeps(binaryPath) {
  const stopDeviceStreamsCalls = [];
  const stopAllStreamsCalls = [];
  const posts = [];
  const deps = {
    workspaceRoot: "/tmp",
    getConfig: () => ({ binaryPath, project: "P", profile: "" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
    writeMonitorControl: () => {},
    notifyMachineProfilesChanged: () => {},
    stopDeviceStreams: (name) => stopDeviceStreamsCalls.push(name),
    stopAllStreams: () => stopAllStreamsCalls.push(true),
  };
  return { deps, stopDeviceStreamsCalls, stopAllStreamsCalls, posts };
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

/** 引数を args.log へ追記してから exit 0 する mock fleetest。 */
function makeArgRecordingBinary() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-args-test-"));
  const binaryPath = path.join(dir, "fleetest");
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

// ---- device-down 直指定モード(未登録デバイス。udid/serial 指定時の引数組み立て) ----
// 対向: Sources/fleetest/ApiDeviceCommands.swift ApiDeviceDownDirectTarget(--name/--udid/--serial の
// うちちょうど1つ)。monitorDeviceOps.ts runDeviceOpAttempt が --name の代わりに --udid/--serial を
// 渡し、--project/--profile も付けないことを spawn 引数で検証する。

/** device ジョブを1件流し、mock が記録した引数行を返す。 */
async function runDeviceJobAndReadArgs(deviceOps, argsLog, job) {
  deviceOps.enqueueLifecycleJob(job);
  await waitUntilIdle(deviceOps);
  return fs.existsSync(argsLog) ? fs.readFileSync(argsLog, "utf8") : "";
}

test("device-down は udid 指定時、--udid を渡し --name/--project/--profile を渡さない", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  const args = await runDeviceJobAndReadArgs(deviceOps, argsLog, {
    kind: "device",
    name: "iPhone 17 Pro",
    op: "down",
    udid: "ABCD-1234",
  });
  assert.match(args, /--udid ABCD-1234/);
  assert.doesNotMatch(args, /--name/);
  assert.doesNotMatch(args, /--project/);
  assert.doesNotMatch(args, /--profile/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("device-up は udid 指定時、--udid を渡す(接続中の実機のブリッジ起動)", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  const args = await runDeviceJobAndReadArgs(deviceOps, argsLog, {
    kind: "device",
    name: "iPhone SE3",
    op: "up",
    udid: "00008110-000260242EEB801E",
  });
  assert.match(args, /device-up/);
  assert.match(args, /--udid 00008110-000260242EEB801E/);
  assert.doesNotMatch(args, /--name/);
  assert.doesNotMatch(args, /--project/);
  assert.doesNotMatch(args, /--profile/);
  fs.rmSync(dir, { recursive: true, force: true });
});

// Android の up に直指定は無い(端末の電源を入れる操作は存在しない)。serial 付きの up は
// 従来どおり --name 経路へ落ちること
test("device-up は serial 指定でも直指定にせず --name 経路のまま", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  const args = await runDeviceJobAndReadArgs(deviceOps, argsLog, {
    kind: "device",
    name: "Pixel_9_Android_15_-01",
    op: "up",
    serial: "emulator-5554",
  });
  assert.match(args, /--name Pixel_9_Android_15_-01/);
  assert.doesNotMatch(args, /--serial emulator-5554/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("device-down は serial 指定時、--serial を渡し --name/--project/--profile を渡さない", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  const args = await runDeviceJobAndReadArgs(deviceOps, argsLog, {
    kind: "device",
    name: "Pixel_9_Android_15_-01",
    op: "down",
    serial: "emulator-5554",
  });
  assert.match(args, /--serial emulator-5554/);
  assert.doesNotMatch(args, /--name/);
  assert.doesNotMatch(args, /--project/);
  assert.doesNotMatch(args, /--profile/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("device-down は udid/serial 無指定なら従来どおり --name/--project/--profile を渡す", async () => {
  const { dir, binaryPath, argsLog } = makeArgRecordingBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);

  const args = await runDeviceJobAndReadArgs(deviceOps, argsLog, {
    kind: "device",
    name: "シミュ1",
    op: "down",
  });
  assert.match(args, /--name シミュ1/);
  assert.match(args, /--project P/);
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

// --- 手動 Wipe Data(プロファイルタブのデバイス行右クリック) --------------------------------

test("wipe ジョブは api device-wipe を --name/--project/--device-machine で撃つ", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    assert.equal(deviceOps.enqueueWipe([{ name: "エミュ1" }]), 1);
    await waitUntilIdle(deviceOps);
    const line = argvLines(dir).at(-1);
    assert.match(line, /^api device-wipe /);
    assert.match(line, /--name エミュ1/);
    assert.match(line, /--project P/);
    assert.match(line, /--device-machine local/, "手元でも絞る(同名のリモートの台を引かない)");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("リモートの台の wipe はその機械で実行する(remote exec + --device-machine)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueWipe([{ name: "エミュ1", machine: "M1Max" }]);
    await waitUntilIdle(deviceOps);
    const line = argvLines(dir).at(-1);
    assert.match(line, /^remote exec M1Max -- api device-wipe/);
    assert.match(line, /--device-machine M1Max/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("wipe ジョブは down と同じく実行開始時に stopDeviceStreams を呼ぶ(中で必ず停止するため)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, stopDeviceStreamsCalls, stopAllStreamsCalls } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueWipe([{ name: "エミュ1" }]);
    assert.deepEqual(stopDeviceStreamsCalls, ["エミュ1"]);
    assert.deepEqual(stopAllStreamsCalls, []);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("同じ台に別の操作が載っている間は wipe を積まない(戻り値0)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "エミュ1", op: "down" });
    assert.equal(deviceOps.enqueueWipe([{ name: "エミュ1" }]), 0);
    // 別の機械の同名は別の台なので積める((machine, name) で引く)
    assert.equal(deviceOps.enqueueWipe([{ name: "エミュ1", machine: "M1Max" }]), 1);
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- 別の機械のデバイスの単体操作 ---------------------------------------------------------
// 実害の形(2026-08-17 のレビュー): `api device-up --name X` は**手元の**マシンプロファイルを
// 名前だけで引く(ApiDeviceOperation.findDevice)。同名の台が別の機械にも居るのは通常なので、
// リモートのタイルから起動すると**別の機械の設定でこの Mac にシミュレータが1台できる**
// (simctl は無ければ作る)。一括起動が RemoteDeviceFanout で分散するのと同じ規律に揃える。

test("リモートのデバイスの起動はその機械で実行する(remote exec + --device-machine)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "up", machine: "M1Max" });
    await waitUntilIdle(deviceOps);
    const line = argvLines(dir).at(-1);
    assert.match(line, /^remote exec M1Max -- api device-up/, "その機械で起こす");
    assert.match(line, /--device-machine M1Max/, "向こうは自分が誰かを知らない");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// **再試行も同じ機械で走らせる**(実害 2026-08-29): 落とすと再試行だけ手元で走り、
// 別の機械の実機に対して「そんな UDID の実機は無い(認識しているのは…手元の3台)」という
// 見当違いのエラーが最後に出て、本当の失敗理由(向こうの署名エラー)が隠れた。
test("up の再試行もその機械で実行する(machine を落とさない)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-retry-"));
  const binaryPath = path.join(dir, "fleetest");
  // 1回目だけ失敗して再試行を起こし、2回目は成功してキューを空にする
  fs.writeFileSync(binaryPath, `#!/bin/sh
echo "$@" >> "${path.join(dir, "argv")}"
if [ -f "${path.join(dir, "failed-once")}" ]; then exit 0; fi
touch "${path.join(dir, "failed-once")}"
exit 1
`);
  fs.chmodSync(binaryPath, 0o755);
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({
      kind: "device", name: "iPhone 13", op: "up", machine: "M1Ultra",
      udid: "00008110-001460910E0A201E",
    });
    // 再試行は 3 秒後。キューが空くまで(= 2回目が終わるまで)待つ
    await waitUntilIdle(deviceOps, 10000);
    const lines = argvLines(dir);
    assert.equal(lines.length, 2, "1回目 + 再試行");
    for (const [index, line] of lines.entries()) {
      assert.match(line, /^remote exec M1Ultra -- api device-up/, `${index + 1}回目もその機械で起こす`);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("手元のデバイスは remote exec を経由せず、手元の台に絞られる", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "up" });
    await waitUntilIdle(deviceOps);
    const line = argvLines(dir).at(-1);
    assert.match(line, /^api device-up/);
    assert.doesNotMatch(line, /remote exec/);
    assert.match(line, /--device-machine local/, "同名のリモートの台を引かないための絞り込み");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// キュー状態(deviceOpBusy)は **(name, machine)** で宛先を決める。machine を載せないと webview が
// 同名の先頭のタイル(= 手元)を書き換え、「別の機械の台を停止」で手元のタイルに
// 「シャットダウン中」が出る(2026-08-17 の実害)。
test("リモートのジョブのキュー状態には machine が載る", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "down", machine: "M1Max" });
    const busy = posts.filter((m) => m.type === "deviceOpBusy" && m.name === "シミュ1");
    assert.ok(busy.length > 0, "前提: キュー状態が送られる");
    assert.ok(busy.every((m) => m.machine === "M1Max"), "宛先のタイルを特定できる machine が要る");
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("手元のジョブのキュー状態は machine を持たない(= 手元の意味)", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "down" });
    const busy = posts.filter((m) => m.type === "deviceOpBusy" && m.name === "シミュ1");
    assert.ok(busy.length > 0);
    assert.ok(busy.every((m) => m.machine === undefined));
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// 同名の台を2機で同時に操作しても、状態が混ざらないこと。**キューの照会が名前だけだと
// 先に見つかったジョブの op を両方のタイルへ出す**(「起動中」のはずの台が「停止中」になる)。
test("同名の台を2機で同時に操作しても、それぞれのタイルに自分の状態が出る", async () => {
  const { dir, binaryPath } = makeMockBinary();
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "down", machine: "M1Max" });
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シミュ1", op: "up" });

    const busy = posts.filter((m) => m.type === "deviceOpBusy" && m.name === "シミュ1" && m.op);
    const remote = busy.filter((m) => m.machine === "M1Max");
    const local = busy.filter((m) => m.machine === undefined);
    assert.ok(remote.length > 0 && local.length > 0,
      "別の機械の同名ジョブが手元の操作を握りつぶしてはいけない");
    assert.ok(remote.every((m) => m.op === "down"), "M1Max の台は停止中");
    assert.ok(local.every((m) => m.op === "up"), "手元の台は起動中");
    // **機械が違えば並行してよい** —— 同じデバイスへの二重操作を避けるガードを名前だけで
    // 見ると、別の機械の同名の台が「同じデバイス」に見えて直列化される
    assert.ok(remote.some((m) => m.status === "running"), "M1Max の台は実行中まで進む");
    assert.ok(local.some((m) => m.status === "running"), "手元の台も待たされずに実行中まで進む");
    await waitUntilIdle(deviceOps);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---- 失敗メッセージに添える stderr の1行 ----
// exit code だけを出していたため、`remote exec` の exit 91(発行者のワークスペースが無い)が
// 「installed-devices が失敗しました(exit code: 91)」としか見えず、対処が分からなかった実害の回帰。

test("stderrDetailLine: 進捗見出しを飛ばして最後の実質行(対処つき)を採る", () => {
  const stderr = [
    "==> host M1Ultra → wave1008@192.168.20.95",
    "no runner workspace at /Users/x/fleetest-runner/users/y/work — run: fleetest remote setup <this host>",
    "this issuer has no runner workspace on wave1008@192.168.20.95 yet — run `fleetest remote setup ...`",
    "",
  ].join("\n");
  assert.equal(
    stderrDetailLine(stderr),
    "this issuer has no runner workspace on wave1008@192.168.20.95 yet — run `fleetest remote setup ...`",
  );
});

test("stderrDetailLine: 進捗見出しだけ・空なら null(従来の exit code 文言へ落ちる)", () => {
  assert.equal(stderrDetailLine("==> host M1Ultra → wave1008@192.168.20.95\n"), null);
  assert.equal(stderrDetailLine("   \n\n"), null);
  assert.equal(stderrDetailLine(""), null);
});

test("stderrDetailLine: 長い行は切り詰める(webview の1行表示に収める)", () => {
  const long = "x".repeat(500);
  const detail = stderrDetailLine(long, 200);
  assert.equal(detail.length, 201, "上限200文字+省略記号");
  assert.ok(detail.endsWith("…"));
  // 上限ちょうどは切らない
  assert.equal(stderrDetailLine("y".repeat(200), 200), "y".repeat(200));
});

// ---- バナーは1行だけ(firstLine)----
// 実機の署名エラーは xcodebuild のビルドログが数十行そのまま返る。全文をバナーへ流すと
// パネルが埋まって読めない(実害 2026-08-29)。CLI は「1行目だけで用が足りる」形で返す
// 契約(FTBridgeClient の XcodeSigningDiagnosis)なので、バナーは先頭行を採る。

test("firstLine: 複数行のうち先頭の実質行だけを採る", () => {
  const guidance = [
    "Cannot code-sign the bridge runner for a physical device on this Mac.",
    "  1. Xcode ▸ Settings ▸ Accounts: add your Apple ID",
    "Full xcodebuild output: /tmp/bridge-build-8123.log",
  ].join("\n");
  assert.equal(firstLine(guidance), "Cannot code-sign the bridge runner for a physical device on this Mac.");
});

test("firstLine: 先頭の空行は飛ばし、長すぎる行は切る", () => {
  assert.equal(firstLine("\n\n  実質行  \n次"), "実質行");
  assert.equal(firstLine("x".repeat(250)), "x".repeat(200) + "…");
});

test("firstLine: 1行だけのエラーはそのまま(既存の見え方を変えない)", () => {
  assert.equal(firstLine("no simulator with that UDID"), "no simulator with that UDID");
});

// ---- 実機の署名エラーの案内(signingGuidance)----
// **判定は CLI・文言は拡張**(CLAUDE.md「共有するのは判定であって文言ではない」)。CLI の error は
// 英語(CLI 利用者向け)なので、拡張は機械可読の signingProblems から自分の言語で組み立て直す。

test("signingGuidance: 案内は2行だけ(どこを直すか + 生ログの在り処)", () => {
  const guidance = signingGuidance(
    ["noAccount", "invalidCertificate", "deviceNotInProfile"], "/tmp/bridge-build-8123.log");
  const lines = guidance.split("\n");
  assert.equal(lines.length, 2, guidance);
  assert.match(lines[0], /実機用のブリッジに署名できません/);
  assert.equal(lines[1], "xcodebuild の全出力: /tmp/bridge-build-8123.log");
  // **直し方は書かない**(ユーザー決定 2026-08-29)—— Xcode も macOS も版ごとに手順が変わり、
  // 書いた手順は必ず古くなる。放っておくと案内は手順と説明で膨らむので機械で止める
  for (const forbidden of ["1.", "▸", "Apple ID", "キーチェーン", "デベロッパモード",
                           "developmentTeam", "証明書"]) {
    assert.doesNotMatch(guidance, new RegExp(forbidden.replace(".", "\\.")), forbidden);
  }
});

test("signingGuidance: 生ログを残せなければ在り処は書かない・空なら CLI の文言に譲る", () => {
  assert.equal(signingGuidance(["noAccount"], undefined).includes("\n"), false);
  assert.equal(signingGuidance([], undefined), null);
});

// **種別は見ない** —— どれでも案内は同じなので、CLI が判定を増やしても拡張は壊れない
test("signingGuidance: 知らない種別でも同じ案内を出す", () => {
  assert.equal(signingGuidance(["somethingNew"], undefined), signingGuidance(["noAccount"], undefined));
});

test("署名の案内は全文がバナーへ渡る(2行)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-signing-"));
  const binaryPath = path.join(dir, "fleetest");
  const finished = JSON.stringify({
    kind: "finished", ok: false, error: "Cannot code-sign … (English)",
    signingProblems: ["noAccount", "invalidCertificate", "deviceNotInProfile"],
    signingLogPath: "/tmp/bridge-build-8123.log",
  });
  // **printf '%s' を使う** —— echo は引数中の \n を展開する処理系があり、JSON が複数行に割れる
  fs.writeFileSync(binaryPath, `#!/bin/sh\nprintf '%s\\n' '${finished}'\nexit 1\n`);
  fs.chmodSync(binaryPath, 0o755);
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "iPhone 13", op: "down" });
    await waitUntilIdle(deviceOps);
    const failed = posts.filter((m) => m.type === "deviceOpFailed").at(-1);
    assert.ok(failed, "deviceOpFailed が送られる");
    assert.match(failed.message, /実機用のブリッジに署名できません/, "拡張の言語で組み立てる");
    assert.match(failed.message, /xcodebuild の全出力: \/tmp\/bridge-build-8123\.log/, "生ログの在り処");
    assert.equal(failed.message.split("\n").length, 2, "2行だけ");
    assert.doesNotMatch(failed.message, /出力ビュー|OUTPUT/, "OUTPUT へは誘導しない");
    assert.doesNotMatch(failed.message, /English/, "CLI の英語は使わない");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("生のエラー(署名以外)は1行目だけ渡す(長いビルドログでパネルを埋めない)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-raw-"));
  const binaryPath = path.join(dir, "fleetest");
  const finished = JSON.stringify({
    kind: "finished", ok: false, error: "xcodebuild failed:\nline2\nline3\nline4",
  });
  // **printf '%s' を使う** —— echo は引数中の \n を展開する処理系があり、JSON が複数行に割れる
  fs.writeFileSync(binaryPath, `#!/bin/sh\nprintf '%s\\n' '${finished}'\nexit 1\n`);
  fs.chmodSync(binaryPath, 0o755);
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シム1", op: "down" });
    await waitUntilIdle(deviceOps);
    const failed = posts.filter((m) => m.type === "deviceOpFailed").at(-1);
    assert.equal(failed.message, "xcodebuild failed:");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// **NDJSON を1行も出さずに落ちる失敗**(引数エラー・プロファイル解決の失敗など)。理由は
// stderr にしか無いので、控えていないとバナーが空のまま = タイルの操作が無反応に見える
// (実害 2026-08-29: 「(プロファイルなし)」でブリッジ起動が何も出さずに失敗した)
test("NDJSON を出さずに落ちたら stderr の理由をバナーへ出す", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-nondjson-"));
  const binaryPath = path.join(dir, "fleetest");
  fs.writeFileSync(binaryPath,
    "#!/bin/sh\nprintf '%s\\n' '→ resolving' 'machine profile not found: local+remote' >&2\nexit 1\n");
  fs.chmodSync(binaryPath, 0o755);
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "iPhone 13", op: "down" });
    await waitUntilIdle(deviceOps);
    const failed = posts.filter((m) => m.type === "deviceOpFailed").at(-1);
    assert.ok(failed, "deviceOpFailed が送られる");
    assert.equal(failed.message, "machine profile not found: local+remote", "stderr の最後の実質行");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("stderr が何も無ければ exit code だけでもバナーへ出す(黙って失敗しない)", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-deviceops-silent-"));
  const binaryPath = path.join(dir, "fleetest");
  fs.writeFileSync(binaryPath, "#!/bin/sh\nexit 3\n");
  fs.chmodSync(binaryPath, 0o755);
  const { deps, posts } = makeDeps(binaryPath);
  const deviceOps = new MonitorDeviceOps(deps);
  try {
    deviceOps.enqueueLifecycleJob({ kind: "device", name: "シム1", op: "down" });
    await waitUntilIdle(deviceOps);
    const failed = posts.filter((m) => m.type === "deviceOpFailed").at(-1);
    assert.ok(failed, "deviceOpFailed が送られる");
    assert.match(failed.message, /3/, "exit code が読める");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
