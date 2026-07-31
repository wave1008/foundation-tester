// remoteRunArgs.test.mjs
// remoteRunArgs.ts(resolveRemoteTarget/buildRemoteRunArgs/normalizeRemoteHosts)のユニットテスト。
// node:test で実行する。esbuild が "../src/remoteRunArgs"(拡張子なし)を remoteRunArgs.ts に
// 解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { buildRemoteRunArgs, normalizeRemoteHosts, resolveRemoteTarget } from "../src/remoteRunArgs";

const HOSTS = [
  { name: "mac-01", host: "user@mac-01", dir: "", session: "asuser" },
  { name: "mac-02", host: "mac-02", dir: "/Users/ci/ftester-runner", session: "direct" },
  { name: "broken", host: "", dir: "", session: "asuser" },
];

test("resolveRemoteTarget: target 空 → local", () => {
  assert.deepEqual(resolveRemoteTarget("", HOSTS), { kind: "local" });
  assert.deepEqual(resolveRemoteTarget("   ", HOSTS), { kind: "local" });
});

test("resolveRemoteTarget: hosts と一致 → remote(entry を返す)", () => {
  assert.deepEqual(resolveRemoteTarget("mac-01", HOSTS), { kind: "remote", entry: HOSTS[0] });
});

test("resolveRemoteTarget: hosts に無い名前 → error", () => {
  assert.deepEqual(resolveRemoteTarget("no-such-host", HOSTS), { kind: "error", target: "no-such-host" });
});

test("resolveRemoteTarget: 一致するが host が空(壊れた登録) → error", () => {
  assert.deepEqual(resolveRemoteTarget("broken", HOSTS), { kind: "error", target: "broken" });
});

test("buildRemoteRunArgs: dir・session 既定省略(host のみ)", () => {
  assert.deepEqual(
    buildRemoteRunArgs({ name: "mac-01", host: "user@mac-01", dir: "", session: "direct" }),
    ["--host", "user@mac-01"],
  );
});

test("buildRemoteRunArgs: asuser 指定", () => {
  assert.deepEqual(
    buildRemoteRunArgs({ name: "mac-02", host: "mac-02", dir: "", session: "asuser" }),
    ["--host", "mac-02", "--remote-session", "asuser"],
  );
});

test("buildRemoteRunArgs: 全指定(host + dir + asuser)", () => {
  assert.deepEqual(
    buildRemoteRunArgs({
      name: "mac-02",
      host: "mac-02",
      dir: "/Users/ci/ftester-runner",
      session: "asuser",
    }),
    ["--host", "mac-02", "--remote-dir", "/Users/ci/ftester-runner", "--remote-session", "asuser"],
  );
});

test("normalizeRemoteHosts: 配列でない/不正要素は除去", () => {
  assert.deepEqual(normalizeRemoteHosts(undefined), []);
  assert.deepEqual(normalizeRemoteHosts(null), []);
  assert.deepEqual(
    normalizeRemoteHosts([null, "not-an-object", 42, { name: "", host: "" }]),
    [],
  );
});

test("normalizeRemoteHosts: name 空なら host を name に補完", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "", host: "user@mac-01", dir: "", session: "asuser" }]),
    [{ name: "user@mac-01", host: "user@mac-01", dir: "", session: "asuser" }],
  );
});

test("normalizeRemoteHosts: host 空でも name があれば残す(resolveRemoteTarget が error 判定に使う)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "broken", host: "", dir: "", session: "asuser" }]),
    [{ name: "broken", host: "", dir: "", session: "asuser" }],
  );
});

test("normalizeRemoteHosts: session は asuser/direct 以外なら direct に落とす", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "x", host: "h", dir: "", session: "bogus" }]),
    [{ name: "x", host: "h", dir: "", session: "direct" }],
  );
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "x", host: "h", dir: "", session: undefined }]),
    [{ name: "x", host: "h", dir: "", session: "direct" }],
  );
});

test("normalizeRemoteHosts: 型不正フィールドは空文字扱い(dir/host が string でない)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "x", host: 123, dir: null, session: "direct" }]),
    [{ name: "x", host: "", dir: "", session: "direct" }],
  );
});
