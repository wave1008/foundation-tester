// remoteRunArgs.test.mjs
// remoteRunArgs.ts(normalizeRemoteHosts/parseRemoteHostsResponse/diffRemoteHostsForSync/
// deviceCommandArgs)のユニットテスト。node:test で実行する。
// esbuild が "../src/remoteRunArgs"(拡張子なし)を remoteRunArgs.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  deviceCommandArgs,
  diffRemoteHostsForSync,
  mergeRemoteHostsSideFields,
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

// machine 空欄は host の**ホスト部**で埋める(user@ は落とす)。丸ごと流用すると、
// 登録名に使えない文字("@")を含む名前になり CLI の validateName に弾かれる。
// 規則は remoteRunArgs.ts の defaultMachineForHost(Swift 側と対。
// remoteHostDefaultMachine.test.mjs が同期を見る)
test("normalizeRemoteHosts: machine 空なら host のホスト部を流用", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "", host: "user@mac-01", dir: "" }]),
    [{ machine: "mac-01", host: "user@mac-01", dir: "", fmConcurrency: 0 }],
  );
});

test("normalizeRemoteHosts: host 空でも machine があれば残す(壊れた登録として設定タブにそのまま出す)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "broken", host: "", dir: "" }]),
    [{ machine: "broken", host: "", dir: "", fmConcurrency: 0 }],
  );
});

test("normalizeRemoteHosts: 型不正フィールドは空文字扱い(dir/host が string でない)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "x", host: 123, dir: null }]),
    [{ machine: "x", host: "", dir: "", fmConcurrency: 0 }],
  );
});

test("normalizeRemoteHosts: machine は CLI 契約どおり保持する(§13 のキャッシュ)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "mac-02", host: "mac-02", dir: "" }]),
    [{ machine: "mac-02", host: "mac-02", dir: "", fmConcurrency: 0 }],
  );
});

test("parseRemoteHostsResponse: {hosts:[…]} を正規化して返す", () => {
  assert.deepEqual(
    parseRemoteHostsResponse({ hosts: [{ machine: "mac-01", host: "user@mac-01", dir: "" }] }),
    [{ machine: "mac-01", host: "user@mac-01", dir: "", fmConcurrency: 0 }],
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

test("deviceCommandArgs: remote は `remote exec <machine> -- <apiArgs>` へ包む", () => {
  assert.deepEqual(
    deviceCommandArgs({ kind: "remote", machine: "M1Max" }, ["api", "installed-devices"]),
    ["remote", "exec", "M1Max", "--", "api", "installed-devices"],
  );
  assert.deepEqual(
    deviceCommandArgs({ kind: "remote", machine: "M1Max" }, ["api", "device-catalog"]),
    ["remote", "exec", "M1Max", "--", "api", "device-catalog"],
  );
});

test("deviceCommandArgs: remote は apiArgs を変更しない(呼び出し側の配列を書き換えない)", () => {
  const apiArgs = ["api", "create-device", "--name", "foo"];
  const result = deviceCommandArgs({ kind: "remote", machine: "studio" }, apiArgs);
  assert.deepEqual(apiArgs, ["api", "create-device", "--name", "foo"], "元の配列は不変");
  assert.deepEqual(result, ["remote", "exec", "studio", "--", "api", "create-device", "--name", "foo"]);
});

// **旧キー "name" も読む**(改名の互換。既に登録簿を持っている受け手は無改修で動く)
test("normalizeRemoteHosts: 旧キー name も読む(machine が優先)", () => {
  assert.deepEqual(
    normalizeRemoteHosts([{ name: "M1Ultra", host: "user@mac-01", dir: "" }]),
    [{ machine: "M1Ultra", host: "user@mac-01", dir: "", fmConcurrency: 0 }],
  );
  assert.deepEqual(
    normalizeRemoteHosts([{ machine: "new", name: "old", host: "h", dir: "" }]),
    [{ machine: "new", host: "h", dir: "", fmConcurrency: 0 }],
  );
});

// FM 並列枠だけを変えた編集が「変更なし」と判定されると、CLI へ届かないまま直後の
// remoteConfig が入力を古い値へ戻す = **打った値が消える**(2026-09-02 の実害)
test("diffRemoteHostsForSync: FM 並列枠だけの変更も upsert 対象", () => {
  const previous = [{ machine: "M1Ultra", host: "user@h", dir: "", fmConcurrency: 0 }];
  const next = [{ machine: "M1Ultra", host: "user@h", dir: "", fmConcurrency: 1 }];
  const { upserts, removedNames } = diffRemoteHostsForSync(previous, next);
  assert.equal(removedNames.length, 0);
  assert.deepEqual(upserts.map((h) => h.fmConcurrency), [1]);
});

test("diffRemoteHostsForSync: 何も変わっていなければ upsert しない", () => {
  const same = [{ machine: "M1Ultra", host: "user@h", dir: "", fmConcurrency: 1 }];
  assert.equal(diffRemoteHostsForSync(same, same).upserts.length, 0);
});

// normalizeRemoteHosts が欄を落とすと、diff の previous 側が常に未設定になり上と同じ実害が出る
test("normalizeRemoteHosts: fmConcurrency を落とさない", () => {
  const [row] = normalizeRemoteHosts([{ machine: "M1Ultra", host: "user@h", dir: "", fmConcurrency: 2 }]);
  assert.equal(row.fmConcurrency, 2);
  const [unset] = normalizeRemoteHosts([{ machine: "M1Max", host: "user@h", dir: "" }]);
  assert.equal(unset.fmConcurrency, 0, "未設定は 0");
});

// 応答の欄の据え置き。**書き込み(--import/--remove)の応答からも控えを更新する**のが要点 ——
// 読み取り時にしか控えないと、書き込み直後に webview へ送り返す local が古いままになり、
// 固定行(この機械)に打った FM 枠が打った瞬間に元へ戻る(= 変更できない)
test("mergeRemoteHostsSideFields: 応答の欄で更新し、無い欄は据え置く", () => {
  const previous = { defaultFMConcurrency: 5,
                     local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } };

  const written = mergeRemoteHostsSideFields(previous, {
    defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 3 },
  });
  assert.equal(written.local.fmConcurrency, 3, "書き込み後の値を控える");

  // 失敗応答(欄が無い)で控えを消さない —— 消すと固定行が画面から消える
  const failed = mergeRemoteHostsSideFields(previous, {});
  assert.equal(failed.local.fmConcurrency, 0);
  assert.equal(failed.defaultFMConcurrency, 5);
});
