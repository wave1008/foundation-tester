// monitorProcessManager.test.mjs
// MonitorProcessManager(src/monitorProcessManager.ts)の spawn 呼び出し引数の回帰テスト。node:test。
// esbuild が "../src/monitorProcessManager" を .ts に解決してバンドルする。
//
// コンストラクタ第2引数(spawnFn)はテスト専用の差し替え口(既定は実 spawn。monitorProcessManager.ts
// 参照)。本番経路(monitorPanel.ts の `new MonitorProcessManager(this.deps)`)は未指定のままなので
// 挙動は変わらない。

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { MonitorProcessManager } from "../src/monitorProcessManager";

/** spawn が返す ChildProcess の代わりに使う最小 fake(stdin/stdout/stderr + on/kill)。 */
function makeFakeProc() {
  const proc = new EventEmitter();
  proc.stdin = Object.assign(new EventEmitter(), { end() {}, write() {} });
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.exitCode = null;
  proc.signalCode = null;
  proc.kill = () => {};
  return proc;
}

function makeDeps(overrides = {}) {
  return {
    workspaceRoot: "/tmp/proj",
    outputChannel: { appendLine() {} },
    post: () => {},
    isPanelActive: () => true,
    getStreamingDeviceIds: () => [],
    isDeviceStreaming: () => false,
    notifyMonitorDevices: () => {},
    notifyMachineLocks: () => {},
    getConfig: () => ({
      binaryPath: "/usr/local/bin/fleetest",
      project: "P",
      profile: "",
      monitorInterval: 2,
      monitorMaxWidth: 960,
    }),
    ...overrides,
  };
}

test("startMonitorProcess は `api monitor --project <p> --interval <i> --max-width <w>` で spawnFn を呼ぶ", () => {
  const calls = [];
  const fakeProc = makeFakeProc();
  const spawnFn = (command, args, options) => {
    calls.push({ command, args, options });
    return fakeProc;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);

  manager.startMonitorProcess();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "/usr/local/bin/fleetest");
  assert.deepEqual(calls[0].args, ["api", "monitor", "--project", "P", "--interval", "2", "--max-width", "960"]);
  assert.deepEqual(calls[0].options, { cwd: "/tmp/proj", shell: false, stdio: ["pipe", "pipe", "pipe"] });
});

test("profile 設定時は --profile が args に追加される", () => {
  const calls = [];
  const spawnFn = (command, args, options) => {
    calls.push({ command, args, options });
    return makeFakeProc();
  };
  const deps = makeDeps({
    getConfig: () => ({
      binaryPath: "/usr/local/bin/fleetest",
      project: "P",
      profile: "prof1",
      monitorInterval: 2,
      monitorMaxWidth: 960,
    }),
  });
  const manager = new MonitorProcessManager(deps, spawnFn);

  manager.startMonitorProcess();

  assert.deepEqual(calls[0].args, [
    "api", "monitor", "--project", "P", "--interval", "2", "--max-width", "960", "--profile", "prof1",
  ]);
});

test("startHostMetricsProcess は `api host-metrics --interval 1` で spawnFn を呼ぶ", () => {
  const calls = [];
  const spawnFn = (command, args, options) => {
    calls.push({ command, args, options });
    return makeFakeProc();
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);

  manager.startHostMetricsProcess();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "/usr/local/bin/fleetest");
  assert.deepEqual(calls[0].args, ["api", "host-metrics", "--interval", "1"]);
  assert.deepEqual(calls[0].options, { cwd: "/tmp/proj", shell: false, stdio: ["pipe", "pipe", "pipe"] });
});

// モニターが死んだときのバナー。**CLI が言っている理由を捨てない** ——
// 実害(2026-08-17): 設定の project(E2E-Android)と profile(local+remote)が食い違い、CLI は
// 「run profile not found: local+remote (available: android, android-device)」と正しく言っていたのに、
// 拡張は exit code だけを見て「マシンプロファイル未設定の可能性があります」と表示し、
// 見当違いの場所(profiles/machines/)を調べさせた。
test("モニターの異常終了は CLI の Error 行をそのままバナーに載せる", () => {
  const posts = [];
  const proc = makeFakeProc();
  const manager = new MonitorProcessManager(makeDeps({ post: (m) => posts.push(m) }), () => proc);
  manager.startMonitorProcess();

  proc.stderr.emit("data", Buffer.from("→ Using machine profile M2Ultra automatically\n"));
  proc.stderr.emit("data", Buffer.from("Error: run profile not found: local+remote (available: android)\n"));
  // ArgumentParser は Error の**後ろ**に usage を出す。最後の1行を拾う実装だとこれを理由にする
  proc.stderr.emit("data", Buffer.from("  See 'fleetest api monitor --help' for more information.\n"));
  proc.emit("close", 1, null);

  const down = posts.filter((m) => m.type === "processDown").at(-1);
  assert.ok(down, "processDown が送られる");
  assert.match(down.message, /run profile not found: local\+remote/, "理由をそのまま出す");
  assert.doesNotMatch(down.message, /マシンプロファイル未設定/, "推測の案内で上書きしない");
  assert.doesNotMatch(down.message, /Using machine profile/, "進行ログは理由ではない");
});

test("CLI が何も言わずに落ちたときは従来の案内へ戻る", () => {
  const posts = [];
  const proc = makeFakeProc();
  const manager = new MonitorProcessManager(makeDeps({ post: (m) => posts.push(m) }), () => proc);
  manager.startMonitorProcess();

  proc.emit("close", 1, null);

  const down = posts.filter((m) => m.type === "processDown").at(-1);
  assert.match(down.message, /マシンプロファイル未設定/);
});

// ---- monitor の自動再起動(2026-08-24 追加。host-metrics と同型の give-up 付き) ----
// タイマーは node:test の mock.timers で進める(実時間の 5 秒を待たない)

test("monitor の予期しない close は5秒後に自動再起動する", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const calls = [];
  let current;
  const spawnFn = (command, args) => {
    calls.push(args);
    current = makeFakeProc();
    return current;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);
  manager.startMonitorProcess();
  assert.equal(calls.length, 1);

  // 10 秒以上動いてからの予期しない終了(streak リセット側)
  t.mock.timers.setTime(15000);
  current.emit("close", null, "SIGKILL");
  t.mock.timers.tick(5000);
  assert.equal(calls.length, 2, "close の5秒後に再 spawn される");
});

test("起動10秒未満の異常終了が3連続すると諦め、それ以上再起動しない", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const calls = [];
  let current;
  const spawnFn = (command, args) => {
    calls.push(args);
    current = makeFakeProc();
    return current;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);
  manager.startMonitorProcess();

  for (let i = 0; i < 3; i += 1) {
    // 起動直後(10秒未満)に死ぬ
    t.mock.timers.tick(1000);
    current.emit("close", 1, null);
    t.mock.timers.tick(5000);
  }
  // 3回目の close で give-up: 2回分の再起動 spawn(初回 + 2)で止まる
  assert.equal(calls.length, 3, "give-up 後は再 spawn されない");
  t.mock.timers.tick(60000);
  assert.equal(calls.length, 3);
});

test("stopMonitorProcess 経由の意図した終了では自動再起動しない", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"], now: 0 });
  const calls = [];
  let current;
  const spawnFn = () => {
    calls.push(1);
    current = makeFakeProc();
    return current;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);
  manager.startMonitorProcess();
  t.mock.timers.setTime(15000);
  manager.stopMonitorProcess();
  current.emit("close", 0, null);
  t.mock.timers.tick(10000);
  assert.equal(calls.length, 1, "意図した停止では再 spawn しない");
});

// ---- リモート機の host-metrics(モニターのグラフをマシンごとに出す) ----
// 手元の `api host-metrics` は**この機械しか観測できない**ので、リモート機のぶんはその機械で
// 1本ずつ立てる。専用の ssh 経路は書かず既存の汎用転送(`remote exec`)を使う契約
// (docs/remote-runner.md §14。配信 = device-stream と同じ)。

/** monitorDevices を1行流す(machine 付きのデバイスでリモート機を名乗らせる)。 */
function feedMonitorDevices(proc, devices) {
  const line = JSON.stringify({
    kind: "monitorDevices",
    devices: devices.map((device) => ({
      id: device.id, name: device.name, platform: "ios", state: "connected", detail: "",
      inRun: false, recording: false, registered: true, frozen: false, kind: "virtual",
      ...(device.machine ? { machine: device.machine } : {}),
    })),
  });
  proc.stdout.emit("data", Buffer.from(line + "\n"));
}

test("リモート機のデバイスが居ると `remote exec <machine> -- api host-metrics` を機械ごとに立てる", () => {
  const calls = [];
  const procs = [];
  const spawnFn = (command, args) => {
    calls.push(args);
    const proc = makeFakeProc();
    procs.push(proc);
    return proc;
  };
  const posts = [];
  const manager = new MonitorProcessManager(makeDeps({ post: (m) => posts.push(m) }), spawnFn);
  manager.startAll();
  assert.deepEqual(calls[1], ["api", "host-metrics", "--interval", "1"], "手元のぶんは従来どおり");

  feedMonitorDevices(procs[0], [
    { id: "ios:local1", name: "local1" },
    { id: "ios:mac2/A", name: "A", machine: "mac2" },
    { id: "ios:mac2/B", name: "B", machine: "mac2" },
    { id: "ios:mac3/C", name: "C", machine: "mac3" },
  ]);

  const remote = calls.filter((args) => args[0] === "remote");
  assert.deepEqual(remote, [
    ["remote", "exec", "mac2", "--", "api", "host-metrics", "--interval", "1"],
    ["remote", "exec", "mac3", "--", "api", "host-metrics", "--interval", "1"],
  ], "機械ごとに1本(同じ機械の台が複数あっても1本)");

  const machinesMsg = posts.filter((m) => m.type === "hostMetricsMachines").at(-1);
  assert.deepEqual(machinesMsg.machines, ["mac2", "mac3"], "行の集合を webview へ配る");
});

test("リモート機のサンプルには machine が付く(手元のサンプルには付かない)", () => {
  const procs = [];
  const spawnFn = () => {
    const proc = makeFakeProc();
    procs.push(proc);
    return proc;
  };
  const posts = [];
  const manager = new MonitorProcessManager(makeDeps({ post: (m) => posts.push(m) }), spawnFn);
  manager.startAll();
  feedMonitorDevices(procs[0], [{ id: "ios:mac2/A", name: "A", machine: "mac2" }]);

  const sample = (cpu) => Buffer.from(JSON.stringify({
    kind: "hostMetrics", ts: 1, cpu, gpu: 0.1, memUsedBytes: 2, memTotalBytes: 4,
  }) + "\n");
  procs[1].stdout.emit("data", sample(0.5)); // 手元の host-metrics
  procs[2].stdout.emit("data", sample(0.9)); // mac2 の host-metrics

  const samples = posts.filter((m) => m.type === "hostMetrics");
  assert.equal(samples[0].machine, undefined, "手元は machine を持たない");
  assert.equal(samples[0].cpu, 0.5);
  assert.equal(samples[1].machine, "mac2", "spawn した側が機械名を付ける");
  assert.equal(samples[1].cpu, 0.9);
});

test("リモート機のデバイスが消えたらその機械の子を止め、行の集合からも外す", () => {
  const procs = [];
  const spawnFn = () => {
    const proc = makeFakeProc();
    procs.push(proc);
    return proc;
  };
  const posts = [];
  const manager = new MonitorProcessManager(makeDeps({ post: (m) => posts.push(m) }), spawnFn);
  manager.startAll();
  feedMonitorDevices(procs[0], [{ id: "ios:mac2/A", name: "A", machine: "mac2" }]);
  const remoteProc = procs[2];
  let killed = 0;
  remoteProc.kill = () => { killed += 1; };

  feedMonitorDevices(procs[0], [{ id: "ios:local1", name: "local1" }]);

  assert.ok(killed > 0, "その機械の子を止める");
  assert.deepEqual(posts.filter((m) => m.type === "hostMetricsMachines").at(-1).machines, []);
});

test("同じ機械の集合が続く間は子を立て直さない(監視サイクル毎の ssh churn を作らない)", () => {
  const calls = [];
  const procs = [];
  const spawnFn = (command, args) => {
    calls.push(args);
    const proc = makeFakeProc();
    procs.push(proc);
    return proc;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);
  manager.startAll();
  for (let i = 0; i < 5; i += 1) {
    feedMonitorDevices(procs[0], [{ id: "ios:mac2/A", name: "A", machine: "mac2" }]);
  }
  assert.equal(calls.filter((args) => args[0] === "remote").length, 1);
});

test("全停止(パネルを閉じる・掃討)のあとの「モニター再起動」は消えた機械の ssh を張り直さない", () => {
  const calls = [];
  const procs = [];
  const spawnFn = (command, args) => {
    calls.push(args);
    const proc = makeFakeProc();
    procs.push(proc);
    return proc;
  };
  const manager = new MonitorProcessManager(makeDeps(), spawnFn);
  manager.startAll();
  feedMonitorDevices(procs[0], [{ id: "ios:mac2/A", name: "A", machine: "mac2" }]);
  assert.equal(calls.filter((args) => args[0] === "remote").length, 1);

  manager.stopHostMetricsProcess();
  for (const proc of procs) {
    proc.exitCode = 0;
    proc.emit("close", 0, null); // 実際に畳まれたところまで進める
  }
  calls.length = 0;
  manager.restartAll();

  assert.equal(calls.filter((args) => args[0] === "remote").length, 0, "誰も見ていない機械は張り直さない");
  assert.equal(
    calls.filter((args) => args[0] === "api" && args[1] === "host-metrics").length, 1,
    "手元のぶんは復帰する",
  );
});
