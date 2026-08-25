// 更新チェックの純関数検証(updateCheck.ts / toolRootResolve.ts)。
// 判定そのもの(git の向き・pinned・unknown)は Scripts/update-check.sh 側の責務で、ここでは
// 「スクリプトの出力をどう解釈し、いつ通知するか」だけを見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import {
  CHECK_INTERVAL_MS,
  checkFleetestUpdate,
  decideManualOutcome,
  decideUpdateNotice,
  isCheckDue,
  parseKeyValues,
} from "../src/updateCheck";
import { declaredPackagePath, resolveToolRoot } from "../src/toolRootResolve";

const SAMPLE = [
  "work_dir=/w",
  "tool_root=/t",
  "branch=main",
  "local_head=aaaaaaaabbbbbbbb",
  "dirty=no",
  "remote=origin",
  "remote_ref=refs/heads/main",
  "remote_head=ccccccccdddddddd",
  "verdict=update-available",
  "",
  "🆕 更新があります(ローカル aaaaaaaa → upstream cccccccc)。",
].join("\n");

test("parseKeyValues: key=value 行だけを拾い、人向けの行は無視する", () => {
  const fields = parseKeyValues(SAMPLE);
  assert.equal(fields.verdict, "update-available");
  assert.equal(fields.remote_head, "ccccccccdddddddd");
  assert.equal(fields.branch, "main");
  assert.equal(Object.keys(fields).length, 9);
});

test("parseKeyValues: 値に = を含む行は最初の = で分ける", () => {
  const fields = parseKeyValues("reason=cannot reach upstream (a=b)");
  assert.equal(fields.reason, "cannot reach upstream (a=b)");
});

test("decideUpdateNotice: update-available なら通知する", () => {
  const decision = decideUpdateNotice(parseKeyValues(SAMPLE), undefined);
  assert.equal(decision.kind, "notify");
  assert.equal(decision.remoteHead, "ccccccccdddddddd");
  assert.equal(decision.localHead, "aaaaaaaabbbbbbbb");
});

test("decideUpdateNotice: update-available 以外はすべて黙る", () => {
  for (const verdict of ["up-to-date", "pinned", "unknown", ""]) {
    const decision = decideUpdateNotice({ verdict, remote_head: "ccc" }, undefined);
    assert.equal(decision.kind, "silent", `verdict=${verdict} で通知してしまった`);
  }
});

test("decideUpdateNotice: 却下済みの版は黙るが、次の版が出たら再び通知する", () => {
  const fields = parseKeyValues(SAMPLE);
  assert.equal(decideUpdateNotice(fields, "ccccccccdddddddd").kind, "silent");
  assert.equal(decideUpdateNotice(fields, "0000000011111111").kind, "notify");
});

test("decideUpdateNotice: remote_head が無ければ通知しない(通知しても何も示せない)", () => {
  assert.equal(decideUpdateNotice({ verdict: "update-available" }, undefined).kind, "silent");
});

test("decideManualOutcome: 4つの verdict をそのまま返す(黙る選択肢が無い)", () => {
  assert.deepEqual(decideManualOutcome({ verdict: "up-to-date" }), { kind: "upToDate" });
  // reason は update-check.sh 側の契約で ja/en どちらでも英語(通知に素通しするため)。
  assert.deepEqual(decideManualOutcome({ verdict: "pinned", reason: "version pinned" }), {
    kind: "pinned",
    reason: "version pinned",
  });
  assert.deepEqual(decideManualOutcome({ verdict: "unknown", reason: "cannot reach upstream" }), {
    kind: "unknown",
    reason: "cannot reach upstream",
  });
  assert.deepEqual(decideManualOutcome(parseKeyValues(SAMPLE)), {
    kind: "available",
    localHead: "aaaaaaaabbbbbbbb",
    remoteHead: "ccccccccdddddddd",
  });
});

test("decideManualOutcome: 却下済みの版でも隠さない(自動チェックとの唯一の差)", () => {
  const fields = parseKeyValues(SAMPLE);
  // 自動側は dismissedHead 一致で黙るが、手動は dismissedHead を見ない。
  assert.equal(decideUpdateNotice(fields, "ccccccccdddddddd").kind, "silent");
  assert.equal(decideManualOutcome(fields).kind, "available");
});

test("decideManualOutcome: verdict 行が無い出力は unknown に落とす", () => {
  assert.deepEqual(decideManualOutcome({}), { kind: "unknown", reason: "no verdict" });
  assert.equal(decideManualOutcome({ verdict: "update-available" }).kind, "unknown");
});

test("isCheckDue: 未記録なら実行し、間隔未満は実行しない", () => {
  const now = 1_000_000_000_000;
  assert.equal(isCheckDue(undefined, now), true);
  assert.equal(isCheckDue(now - CHECK_INTERVAL_MS + 1, now), false);
  assert.equal(isCheckDue(now - CHECK_INTERVAL_MS, now), true);
});

test("isCheckDue: 時計が巻き戻っても永久に黙らない", () => {
  const now = 1_000_000_000_000;
  assert.equal(isCheckDue(now + CHECK_INTERVAL_MS * 10, now), true);
  assert.equal(isCheckDue(Number.NaN, now), true);
});

test("declaredPackagePath: 最初の .package(path:) を返す", () => {
  assert.equal(
    declaredPackagePath('dependencies: [.package(path: "../foundation-tester")]'),
    "../foundation-tester",
  );
  assert.equal(declaredPackagePath('.package(url: "https://x/y.git", from: "1.0.0")'), undefined);
});

/** update-check.sh を差し替えたクローンもどきを作る(通知経路には入らない出力を返す)。 */
function fakeClone(verdictLines) {
  const root = mkdtempSync(path.join(tmpdir(), "fleetest-clone-"));
  mkdirSync(path.join(root, "Sources", "FTScenarioRunner"), { recursive: true });
  mkdirSync(path.join(root, "Scripts"), { recursive: true });
  writeFileSync(
    path.join(root, "Scripts", "update-check.sh"),
    `#!/usr/bin/env bash\ncat <<'EOF'\n${verdictLines}\nEOF\n`,
  );
  return root;
}

function fakeState() {
  const store = new Map();
  return {
    get: (key, fallback) => (store.has(key) ? store.get(key) : fallback),
    update: async (key, value) => void store.set(key, value),
    keys: () => [...store.keys()],
    store,
  };
}

const SILENT_CHANNEL = { appendLine() {}, show() {} };

test("checkFleetestUpdate: スクリプトを実行し、最終チェック時刻をクローン単位で記録する", async () => {
  const root = fakeClone("verdict=up-to-date");
  const globalState = fakeState();
  await checkFleetestUpdate({
    workspaceRoot: root,
    enabled: true,
    outputChannel: SILENT_CHANNEL,
    globalState,
    registerChild: () => {},
  });
  const keys = globalState.keys();
  assert.equal(keys.length, 1);
  assert.ok(keys[0].endsWith(`:${root}`), `キーがクローン単位でない: ${keys[0]}`);
  assert.equal(typeof globalState.store.get(keys[0]), "number");
});

test("checkFleetestUpdate: off・未導入・間隔内では実行も記録もしない", async () => {
  const root = fakeClone("verdict=up-to-date");

  const disabled = fakeState();
  await checkFleetestUpdate({
    workspaceRoot: root, enabled: false, outputChannel: SILENT_CHANNEL,
    globalState: disabled, registerChild: () => {},
  });
  assert.deepEqual(disabled.keys(), []);

  // クローンが見つからない(未導入)。
  const noClone = fakeState();
  const lonely = mkdtempSync(path.join(tmpdir(), "fleetest-noclone-"));
  await checkFleetestUpdate({
    workspaceRoot: lonely, enabled: true, outputChannel: SILENT_CHANNEL,
    globalState: noClone, registerChild: () => {},
  });
  assert.deepEqual(noClone.keys(), []);

  // 直前にチェック済み(間隔内)なら時刻を更新しない。
  const recent = fakeState();
  const key = `fleetest.updateCheck.lastCheckedAt:${root}`;
  const stamp = Date.now() - 1000;
  await recent.update(key, stamp);
  await checkFleetestUpdate({
    workspaceRoot: root, enabled: true, outputChannel: SILENT_CHANNEL,
    globalState: recent, registerChild: () => {},
  });
  assert.equal(recent.store.get(key), stamp);
});

test("resolveToolRoot: clone 構成 / 外部構成 / 未導入", () => {
  const base = mkdtempSync(path.join(tmpdir(), "fleetest-toolroot-"));
  const clone = path.join(base, "foundation-tester");
  mkdirSync(path.join(clone, "Sources", "FTScenarioRunner"), { recursive: true });

  // clone 構成: ワークスペース自身がクローン。
  assert.equal(resolveToolRoot(clone), clone);

  // 外部構成: Package.swift の .package(path:) が正(既定の隣とは限らない)。
  const work = path.join(base, "my-tests");
  mkdirSync(work, { recursive: true });
  writeFileSync(path.join(work, "Package.swift"), '.package(path: "../foundation-tester")');
  assert.equal(resolveToolRoot(work), path.join(work, "..", "foundation-tester"));

  // 宣言が無くても既定の隣を見る。
  writeFileSync(path.join(work, "Package.swift"), "// no dependencies");
  assert.equal(resolveToolRoot(work), path.join(work, "..", "foundation-tester"));

  // 未導入(隣にクローンが無い)。
  const lonely = path.join(base, "elsewhere", "my-tests");
  mkdirSync(lonely, { recursive: true });
  assert.equal(resolveToolRoot(lonely), undefined);
});
