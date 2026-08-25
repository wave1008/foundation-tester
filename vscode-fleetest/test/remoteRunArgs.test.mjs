// remoteRunArgs.test.mjs
// remoteRunArgs.ts(normalizeRemoteHosts/parseRemoteHostsResponse/diffRemoteHostsForSync/
// deviceCommandArgs)のユニットテスト。node:test で実行する。
// esbuild が "../src/remoteRunArgs"(拡張子なし)を remoteRunArgs.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  deviceCommandArgs,
  diffRemoteHostsForSync,
  normalizeRemoteHosts,
  parseRemoteHostsResponse,
} from "../src/remoteRunArgs";

test("normalizeRemoteHosts: 配列でない/不正要素は除去", () => {
  assert.deepEqual(normalizeRemoteHosts(undefined), []);
  assert.deepEqual(normalizeRemoteHosts(null), []);
  assert.deepEqual(
    normalizeRemoteHosts([null, "not-an-object", 42, { machine: "", host: "" }]),
    [],
  );
});

test("normalizeRemoteHosts: machine 空なら host を流用", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "", host: "user@mac-01", dir: "" }]),
    [{ machine: "user@mac-01", host: "user@mac-01", dir: "" }],
  );
});

test("normalizeRemoteHosts: host 空でも machine があれば残す(壊れた登録として設定タブにそのまま出す)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "broken", host: "", dir: "" }]),
    [{ machine: "broken", host: "", dir: "" }],
  );
});

test("normalizeRemoteHosts: 型不正フィールドは空文字扱い(dir/host が string でない)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "x", host: 123, dir: null }]),
    [{ machine: "x", host: "", dir: "" }],
  );
});

test("normalizeRemoteHosts: machine は CLI 契約どおり保持する(§13 のキャッシュ)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "mac-02", host: "mac-02", dir: "" }]),
    [{ machine: "mac-02", host: "mac-02", dir: "" }],
  );
});

test("parseRemoteHostsResponse: {hosts:[…]} を正規化して返す", () => {
  assert.deepEqual(
    parseRemoteHostsResponse({ hosts: [{ machine: "mac-01", host: "user@mac-01", dir: "" }] }),
    [{ machine: "mac-01", host: "user@mac-01", dir: "" }],
  );
});

test("parseRemoteHostsResponse: 形が違えば undefined", () => {
  assert.equal(parseRemoteHostsResponse(null), undefined);
  assert.equal(parseRemoteHostsResponse({}), undefined);
  assert.equal(parseRemoteHostsResponse({ hosts: "not-an-array" }), undefined);
  assert.equal(parseRemoteHostsResponse("not-an-object"), undefined);
});

test("diffRemoteHostsForSync: previous に無い名前は全部 upsert 対象", () => {
  const next = [{ machine: "mac-01", host: "user@mac-01", dir: "" }];
  assert.deepEqual(diffRemoteHostsForSync([], next), { removedNames: [], upserts: next });
});

test("diffRemoteHostsForSync: next に無い名前は removedNames、内容不変なら upserts に含めない", () => {
  const previous = [
    { machine: "mac-01", host: "user@mac-01", dir: "" },
    { machine: "mac-02", host: "mac-02", dir: "" },
  ];
  const next = [{ machine: "mac-01", host: "user@mac-01", dir: "" }];
  assert.deepEqual(diffRemoteHostsForSync(previous, next), { removedNames: ["mac-02"], upserts: [] });
});

test("diffRemoteHostsForSync: 同名でも host/dir/machine が変われば upserts に入る", () => {
  const previous = [{ machine: "mac-01", host: "user@mac-01", dir: "" }];
  const next = [{ machine: "mac-01", host: "user@mac-01", dir: "/tmp/runner" }];
  assert.deepEqual(diffRemoteHostsForSync(previous, next), { removedNames: [], upserts: next });
});

test("diffRemoteHostsForSync: rename は旧名の removedNames + 新名の upserts の両方に現れる", () => {
  const previous = [{ machine: "old", host: "user@mac-01", dir: "" }];
  const next = [{ machine: "new", host: "user@mac-01", dir: "" }];
  assert.deepEqual(diffRemoteHostsForSync(previous, next), { removedNames: ["old"], upserts: next });
});

test("deviceCommandArgs: local は apiArgs をそのまま返す(1バイトも変えない契約)", () => {
  assert.deepEqual(
    deviceCommandArgs({ kind: "local" }, ["api", "installed-devices"]),
    ["api", "installed-devices"],
  );
  assert.deepEqual(
    deviceCommandArgs({ kind: "local" }, ["api", "device-catalog"]),
    ["api", "device-catalog"],
  );
});

test("deviceCommandArgs: remote は `remote exec <host> -- <apiArgs>` へ包む", () => {
  assert.deepEqual(
    deviceCommandArgs({ kind: "remote", host: "M1Max" }, ["api", "installed-devices"]),
    ["remote", "exec", "M1Max", "--", "api", "installed-devices"],
  );
  assert.deepEqual(
    deviceCommandArgs({ kind: "remote", host: "M1Max" }, ["api", "device-catalog"]),
    ["remote", "exec", "M1Max", "--", "api", "device-catalog"],
  );
});

test("deviceCommandArgs: remote は apiArgs を変更しない(呼び出し側の配列を書き換えない)", () => {
  const apiArgs = ["api", "create-device", "--name", "foo"];
  const result = deviceCommandArgs({ kind: "remote", host: "studio" }, apiArgs);
  assert.deepEqual(apiArgs, ["api", "create-device", "--name", "foo"], "元の配列は不変");
  assert.deepEqual(result, ["remote", "exec", "studio", "--", "api", "create-device", "--name", "foo"]);
});

// **旧キー "name" も読む**(改名の互換。既に登録簿を持っている受け手は無改修で動く)
test("normalizeRemoteHosts: 旧キー name も読む(machine が優先)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "M1Ultra", host: "user@mac-01", dir: "" }]),
    [{ machine: "M1Ultra", host: "user@mac-01", dir: "" }],
  );
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "new", name: "old", host: "h", dir: "" }]),
    [{ machine: "new", host: "h", dir: "" }],
  );
});
