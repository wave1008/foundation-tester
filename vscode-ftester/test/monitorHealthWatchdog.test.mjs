// monitorHealthWatchdog.test.mjs
// monitorHealthWatchdog.ts(MonitorHealthWatchdog)のユニットテスト。node:test で実行する。
// esbuild が "../src/monitorHealthWatchdog"(拡張子なし)を monitorHealthWatchdog.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { MonitorHealthWatchdog } from "../src/monitorHealthWatchdog";

function device(name, state, health, serial) {
  return { id: name, name, platform: "android", state, detail: "", health, serial };
}

/** テスト用ハーネス。posts/logs/restarts を配列に記録し、now/autoRepair/runActive/queueBusy/wifi 結果を
 * 手元で操作できる。runWifiRepair の解決を手動制御したい場合は wifiResolver を渡す。 */
function createHarness(options = {}) {
  const posts = [];
  const logs = [];
  const restarts = [];
  const wifiCalls = [];
  let currentTime = 0;
  let autoRepairEnabled = options.autoRepairEnabled ?? true;
  let runActive = options.runActive ?? false;
  let queueBusy = options.queueBusy ?? false;
  const wifiResult = options.wifiResult ?? true;

  const watchdog = new MonitorHealthWatchdog({
    post: (message) => posts.push(message),
    log: (message) => logs.push(message),
    enqueueRestart: (name) => restarts.push(name),
    runWifiRepair: async (serial) => {
      wifiCalls.push(serial);
      return wifiResult;
    },
    isAutoRepairEnabled: () => autoRepairEnabled,
    isAnyRunActive: () => runActive,
    isDeviceLifecycleQueueBusy: () => queueBusy,
    now: () => currentTime,
  });

  return {
    watchdog,
    posts,
    logs,
    restarts,
    wifiCalls,
    advance: (ms) => {
      currentTime += ms;
    },
    setAutoRepairEnabled: (value) => {
      autoRepairEnabled = value;
    },
    setRunActive: (value) => {
      runActive = value;
    },
    setQueueBusy: (value) => {
      queueBusy = value;
    },
  };
}

const WIFI_REPAIR_COOLDOWN_MS = 120_000;
const RESTART_COOLDOWN_MS = 5 * 60_000;

test("異常なしの観測では何も post しない", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", undefined, "emulator-5554")]);
  h.watchdog.observe([device("Pixel1", "connected", [], "emulator-5554")]);
  assert.deepEqual(h.posts, []);
  assert.deepEqual(h.restarts, []);
  assert.deepEqual(h.wifiCalls, []);
});

test("wifi-disabled 確定 → unhealthy → repairing(runWifiRepair が serial 付きで呼ばれる)", async () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "repairing" },
  ]);
  assert.deepEqual(h.wifiCalls, ["emulator-5554"]);
  assert.equal(h.restarts.length, 0);
  assert.equal(h.logs.length, 2, "検出ログと修復開始ログでそれぞれ1行");

  // runWifiRepair の非同期解決(then のログ)を待つ。
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(h.logs.length, 3, "修復コマンド実行結果のログが1行追加される");
});

test("同一サイクル内で繰り返し observe しても repairing は再投入しない(冪等)", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.equal(h.wifiCalls.length, 1, "クールダウン中は再修復しない");
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "repairing" },
  ]);
});

test("修復後の異常なし観測 → ok が post されエピソードリセット", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.equal(h.posts.length, 2);

  h.watchdog.observe([device("Pixel1", "connected", undefined, "emulator-5554")]);
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "ok" });

  // リセット後、再び異常が起きれば新たに unhealthy〜repairing が発生する(履歴を引きずらない)。
  const postsBefore = h.posts.length;
  const wifiCallsBefore = h.wifiCalls.length;
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.posts.slice(postsBefore), [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "repairing" },
  ]);
  assert.equal(h.wifiCalls.length, wifiCallsBefore + 1);
});

test("クールダウン中は再修復しない。now を進めると再判定する", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.equal(h.wifiCalls.length, 1);

  h.advance(WIFI_REPAIR_COOLDOWN_MS - 1);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.equal(h.wifiCalls.length, 1, "クールダウン中は追加投入しない");
  // Wi-Fi 修復は1エピソードにつき1回のみのため、クールダウン明けは再修復ではなく restarting へ進む。
  assert.equal(h.restarts.length, 0);

  h.advance(2);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.restarts, ["Pixel1"], "wifi修復済みでも異常継続なら restarting へ昇格する");
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "restarting" });
});

test("wifi 修復後も異常継続 → restarting(enqueueRestart)へ昇格", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  h.advance(WIFI_REPAIR_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.restarts, ["Pixel1"]);
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "repairing" },
    { type: "healthWatch", name: "Pixel1", phase: "restarting" },
  ]);
  assert.equal(h.wifiCalls.length, 1, "wifi修復は1エピソードにつき1回のみ");
});

test("clock-skew は wifi 修復を飛ばして直接 restarting", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "restarting" },
  ]);
  assert.deepEqual(h.restarts, ["Pixel1"]);
  assert.deepEqual(h.wifiCalls, []);
});

test("wifi-disabled と clock-skew が同時なら wifi 修復を飛ばして直接 restarting", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled", "clock-skew"], "emulator-5554")]);
  assert.deepEqual(h.restarts, ["Pixel1"]);
  assert.deepEqual(h.wifiCalls, []);
});

test("MAX_RESTART_ATTEMPTS 到達 → failed、以後 post なし、異常なし観測で復帰", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.equal(h.restarts.length, 1);

  h.advance(RESTART_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.equal(h.restarts.length, 2);

  h.advance(RESTART_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.equal(h.restarts.length, 2, "3回目は投入せず failed になる");
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "failed" });

  // failed 後はいくら異常を観測し続けても post/restart が増えない。
  h.advance(RESTART_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.equal(h.restarts.length, 2);
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "failed" });

  // 異常なし観測で復帰する。
  h.watchdog.observe([device("Pixel1", "connected", undefined, "emulator-5554")]);
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "ok" });
});

test("設定オフでは unhealthy 通知のみで修復しない", () => {
  const h = createHarness({ autoRepairEnabled: false });
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.posts, [{ type: "healthWatch", name: "Pixel1", phase: "unhealthy" }]);
  assert.deepEqual(h.wifiCalls, []);
  assert.deepEqual(h.restarts, []);

  h.setAutoRepairEnabled(true);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.wifiCalls, ["emulator-5554"], "設定が有効化されれば次の観測で修復を試みる");
});

test("run 実行中は unhealthy 通知のみで修復しない", () => {
  const h = createHarness({ runActive: true });
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.posts, [{ type: "healthWatch", name: "Pixel1", phase: "unhealthy" }]);
  assert.deepEqual(h.wifiCalls, []);

  h.setRunActive(false);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.wifiCalls, ["emulator-5554"]);
});

test("ライフサイクルキュー busy 中は unhealthy 通知のみで修復しない", () => {
  const h = createHarness({ queueBusy: true });
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.posts, [{ type: "healthWatch", name: "Pixel1", phase: "unhealthy" }]);
  assert.deepEqual(h.wifiCalls, []);

  h.setQueueBusy(false);
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554")]);
  assert.deepEqual(h.wifiCalls, ["emulator-5554"]);
});

test("state が offline/booted の間はエントリ維持(再起動サイクル中に failed 記憶が消えない)", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  h.advance(RESTART_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  h.advance(RESTART_COOLDOWN_MS);
  h.watchdog.observe([device("Pixel1", "connected", ["clock-skew"], "emulator-5554")]);
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "failed" });
  assert.equal(h.restarts.length, 2);

  // 再起動サイクル中は offline→booted→connected を辿るが、offline/booted の間は何もしてはいけない
  // (failed のまま observe しても post/restart が増えない)。
  h.watchdog.observe([device("Pixel1", "offline", undefined, "emulator-5554")]);
  h.watchdog.observe([device("Pixel1", "booted", undefined, "emulator-5554")]);
  assert.equal(h.restarts.length, 2);
  assert.equal(h.posts.at(-1).phase, "failed", "offline/booted 経由中は failed 記憶が消えない");

  // 異常なしで connected に戻れば復帰する。
  h.watchdog.observe([device("Pixel1", "connected", undefined, "emulator-5554")]);
  assert.deepEqual(h.posts.at(-1), { type: "healthWatch", name: "Pixel1", phase: "ok" });
});

test("serial の無い wifi-disabled(異常系)は restarting へ倒れる", () => {
  const h = createHarness();
  h.watchdog.observe([device("Pixel1", "connected", ["wifi-disabled"], undefined)]);
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "restarting" },
  ]);
  assert.deepEqual(h.wifiCalls, []);
  assert.deepEqual(h.restarts, ["Pixel1"]);
});

test("複数デバイスは独立して状態管理される", () => {
  const h = createHarness();
  h.watchdog.observe([
    device("Pixel1", "connected", ["wifi-disabled"], "emulator-5554"),
    device("Pixel2", "connected", undefined, "emulator-5556"),
  ]);
  assert.deepEqual(h.posts, [
    { type: "healthWatch", name: "Pixel1", phase: "unhealthy" },
    { type: "healthWatch", name: "Pixel1", phase: "repairing" },
  ]);
  assert.deepEqual(h.wifiCalls, ["emulator-5554"]);
});
