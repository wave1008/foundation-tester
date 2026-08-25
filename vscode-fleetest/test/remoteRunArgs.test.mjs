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
    normalizeRemoteHosts([null, "not-an-object", 42, { name: "", host: "" }]),
    [],
  );
});

test("normalizeRemoteHosts: name 空なら host を name に補完", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "", host: "user@mac-01", dir: "" }]),
    [{ name: "user@mac-01", host: "user@mac-01", dir: "", machine: "" }],
  );
});

test("normalizeRemoteHosts: host 空でも name があれば残す(壊れた登録として設定タブにそのまま出す)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "broken", host: "", dir: "" }]),
    [{ name: "broken", host: "", dir: "", machine: "" }],
  );
});

test("normalizeRemoteHosts: 型不正フィールドは空文字扱い(dir/host/machine が string でない)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "x", host: 123, dir: null, machine: 42 }]),
    [{ name: "x", host: "", dir: "", machine: "" }],
  );
});

test("normalizeRemoteHosts: machine は CLI 契約どおり保持する(§13 のキャッシュ)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "mac-02", host: "mac-02", dir: "", machine: "M2Ultra" }]),
    [{ name: "mac-02", host: "mac-02", dir: "", machine: "M2Ultra" }],
  );
});

test("parseRemoteHostsResponse: {hosts:[…]} を正規化して返す", () => {
  assert.deepEqual(
    parseRemoteHostsResponse({ hosts: [{ name: "mac-01", host: "user@mac-01", dir: "", machine: "" }] }),
    [{ name: "mac-01", host: "user@mac-01", dir: "", machine: "" }],
  );
});

test("parseRemoteHostsResponse: 形が違えば undefined", () => {
  assert.equal(parseRemoteHostsResponse(null), undefined);
  assert.equal(parseRemoteHostsResponse({}), undefined);
  assert.equal(parseRemoteHostsResponse({ hosts: "not-an-array" }), undefined);
  assert.equal(parseRemoteHostsResponse("not-an-object"), undefined);
});

test("diffRemoteHostsForSync: previous に無い名前は全部 upsert 対象", () => {
  const next = [{ name: "mac-01", host: "user@mac-01", dir: "", machine: "" }];
  assert.deepEqual(diffRemoteHostsForSync([], next), { removedNames: [], upserts: next });
});

test("diffRemoteHostsForSync: next に無い名前は removedNames、内容不変なら upserts に含めない", () => {
  const previous = [
    { name: "mac-01", host: "user@mac-01", dir: "", machine: "" },
    { name: "mac-02", host: "mac-02", dir: "", machine: "" },
  ];
  const next = [{ name: "mac-01", host: "user@mac-01", dir: "", machine: "" }];
  assert.deepEqual(diffRemoteHostsForSync(previous, next), { removedNames: ["mac-02"], upserts: [] });
});

test("diffRemoteHostsForSync: 同名でも host/dir/machine が変われば upserts に入る", () => {
  const previous = [{ name: "mac-01", host: "user@mac-01", dir: "", machine: "" }];
  const next = [{ name: "mac-01", host: "user@mac-01", dir: "/tmp/runner", machine: "" }];
  assert.deepEqual(diffRemoteHostsForSync(previous, next), { removedNames: [], upserts: next });
});

test("diffRemoteHostsForSync: rename は旧名の removedNames + 新名の upserts の両方に現れる", () => {
  const previous = [{ name: "old", host: "user@mac-01", dir: "", machine: "" }];
  const next = [{ name: "new", host: "user@mac-01", dir: "", machine: "" }];
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
