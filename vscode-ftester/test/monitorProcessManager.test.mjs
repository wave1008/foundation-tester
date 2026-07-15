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
    getConfig: () => ({
      binaryPath: "/usr/local/bin/ftester",
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
  assert.equal(calls[0].command, "/usr/local/bin/ftester");
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
      binaryPath: "/usr/local/bin/ftester",
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
  assert.equal(calls[0].command, "/usr/local/bin/ftester");
  assert.deepEqual(calls[0].args, ["api", "host-metrics", "--interval", "1"]);
  assert.deepEqual(calls[0].options, { cwd: "/tmp/proj", shell: false, stdio: ["pipe", "pipe", "pipe"] });
});
