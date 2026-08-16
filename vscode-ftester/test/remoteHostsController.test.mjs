// remoteHostsController.test.mjs
// resolveRemoteDispatchTarget(remoteHostsController.ts)のユニットテスト。fetchHosts を注入する
// ことで spawn/vscode を経由せず純粋にテストする(runHandler.ts が実行時に使う経路と同じロジック)。
// fetchRemoteHosts/importRemoteHosts/removeRemoteHost 自体は spawn を伴う glue のため、他の単発
// CLI 呼び出し(compatCheck.ts 等)と同様に直接テストしない。

import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveRemoteDispatchTarget } from "../src/remoteHostsController";

test("resolveRemoteDispatchTarget: target 空 → local(fetchHosts は呼ばない)", async () => {
  const result = await resolveRemoteDispatchTarget("", () => {
    throw new Error("fetchHosts must not be called when target is empty");
  });
  assert.deepEqual(result, { kind: "local" });
});

test("resolveRemoteDispatchTarget: target 空白のみ → local", async () => {
  const result = await resolveRemoteDispatchTarget("   ", () => {
    throw new Error("fetchHosts must not be called when target is blank");
  });
  assert.deepEqual(result, { kind: "local" });
});

test("resolveRemoteDispatchTarget: target が登録簿にあれば remote(entry を返す)", async () => {
  const entry = { name: "mac-01", host: "user@mac-01", dir: "", machine: "" };
  const result = await resolveRemoteDispatchTarget("mac-01", async () => [entry]);
  assert.deepEqual(result, { kind: "remote", entry });
});

test("resolveRemoteDispatchTarget: 登録簿に無い名前 → error(黙ってローカルへ落とさない)", async () => {
  const result = await resolveRemoteDispatchTarget("no-such-host", async () => []);
  assert.deepEqual(result, { kind: "error", target: "no-such-host" });
});

test("resolveRemoteDispatchTarget: fetchHosts 失敗(undefined)→ 登録簿0件と同じ扱いで error", async () => {
  const result = await resolveRemoteDispatchTarget("mac-01", async () => undefined);
  assert.deepEqual(result, { kind: "error", target: "mac-01" });
});
