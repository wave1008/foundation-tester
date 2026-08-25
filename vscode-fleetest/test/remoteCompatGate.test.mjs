// remoteCompatGate.test.mjs
// remoteCompatGate.ts(decideRemoteCompat)のユニットテスト。node:test で実行する。
// esbuild が "../src/remoteCompatGate"(拡張子なし)を remoteCompatGate.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { decideRemoteCompat } from "../src/remoteCompatGate";

const okHost = (name) => ({
  name,
  reachable: true,
  revision: "abc1234",
  revisionCompatible: true,
  toolchain: "swift-6.0",
  toolchainCompatible: true,
  error: null,
});

test("hosts が空: proceed(プロファイルにリモート機なし)", () => {
  const decision = decideRemoteCompat({ hosts: [] });
  assert.deepEqual(decision, { kind: "proceed" });
});

test("全ホスト compatible: proceed", () => {
  const decision = decideRemoteCompat({
    hosts: [okHost("M1Max"), okHost("M1Ultra")],
    localRevision: "abc1234",
  });
  assert.deepEqual(decision, { kind: "proceed" });
});

test("rev ズレのみ: ask かつ canUpdate=true・updatableHosts に名前が入る", () => {
  const host = { ...okHost("M1Max"), revision: "deadbee", revisionCompatible: false };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableHosts, ["M1Max"]);
  assert.deepEqual(decision.incompatible, [host]);
  assert.equal(decision.localDirty, false);
  assert.equal(decision.revisionUnpublished, false);
});

test("unreachable が混在: ask かつ canUpdate=false(align では直らない)", () => {
  const reachableButStale = { ...okHost("M1Max"), revisionCompatible: false };
  const unreachable = {
    name: "M1Ultra",
    reachable: false,
    revision: null,
    revisionCompatible: null,
    toolchain: null,
    toolchainCompatible: null,
    error: "connection timed out",
  };
  const decision = decideRemoteCompat({
    hosts: [reachableButStale, unreachable, okHost("M2Studio")],
    revisionPublished: true,
  });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.deepEqual(
    decision.incompatible.map((h) => h.name),
    ["M1Max", "M1Ultra"],
  );
});

test("toolchain ズレ: ask かつ canUpdate=false(align は rev しか直せない)", () => {
  const host = { ...okHost("M1Max"), toolchain: "swift-5.9", toolchainCompatible: false };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
});

test("revisionPublished=false: ask かつ canUpdate=false・revisionUnpublished=true", () => {
  const host = { ...okHost("M1Max"), revisionCompatible: false };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: false, localDirty: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.equal(decision.revisionUnpublished, true);
  assert.equal(decision.localDirty, true);
});

test("revisionRelation=localBehind: ask かつ canUpdate=false・localBehindHosts に名前が入る(この機械が古い側は align で直せない)", () => {
  const host = { ...okHost("M1Max"), revisionCompatible: false, revisionRelation: "localBehind" };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.deepEqual(decision.localBehindHosts, ["M1Max"]);
  assert.deepEqual(decision.divergedHosts, []);
  assert.deepEqual(decision.unknownRelationHosts, []);
});

test("revisionRelation=diverged: ask かつ canUpdate=false・divergedHosts に名前が入る", () => {
  const host = { ...okHost("M1Max"), revisionCompatible: false, revisionRelation: "diverged" };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.deepEqual(decision.divergedHosts, ["M1Max"]);
});

test("revisionRelation=unknown: ask かつ canUpdate=false・unknownRelationHosts に名前が入る", () => {
  const host = { ...okHost("M1Max"), revisionCompatible: false, revisionRelation: "unknown" };
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.deepEqual(decision.unknownRelationHosts, ["M1Max"]);
});

test("revisionRelation=remoteBehind(複数ホスト): canUpdate=true(従来条件を満たす場合)", () => {
  const host1 = { ...okHost("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const host2 = { ...okHost("M1Ultra"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const decision = decideRemoteCompat({ hosts: [host1, host2], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableHosts, ["M1Max", "M1Ultra"]);
});

test("revisionRelation フィールドが無い(旧 CLI の)JSON: 従来と同じ判定(後方互換)", () => {
  const host = { ...okHost("M1Max"), revisionCompatible: false };
  delete host.revisionRelation;
  const decision = decideRemoteCompat({ hosts: [host], revisionPublished: true });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableHosts, ["M1Max"]);
  assert.deepEqual(decision.localBehindHosts, []);
  assert.deepEqual(decision.divergedHosts, []);
  assert.deepEqual(decision.unknownRelationHosts, []);
});

test("localBehind と remoteBehind が混在: canUpdate=false(1機でも align で直らないなら全体を止める)", () => {
  const behind = { ...okHost("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const localBehind = { ...okHost("M1Ultra"), revisionCompatible: false, revisionRelation: "localBehind" };
  const decision = decideRemoteCompat({ hosts: [behind, localBehind], revisionPublished: true });
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableHosts, []);
  assert.deepEqual(decision.localBehindHosts, ["M1Ultra"]);
});

test("壊れた入力(hosts が配列でない/report が null): proceed", () => {
  assert.deepEqual(decideRemoteCompat(null), { kind: "proceed" });
  assert.deepEqual(decideRemoteCompat(undefined), { kind: "proceed" });
  assert.deepEqual(decideRemoteCompat({ hosts: "not-an-array" }), { kind: "proceed" });
  assert.deepEqual(decideRemoteCompat({}), { kind: "proceed" });
});
