// 署名エラー種別のドリフト検出。Swift 側の真実(FTBridgeClient の XcodeSigningProblem の
// case 一覧と needsProvisioningUpdate が true の集合)と、拡張側の SIGNING_FACT_KEYS /
// SIGNING_NEEDS_PORTAL(monitorDeviceOps.ts)が一致することを確認する。
//
// ズレると: Swift に種別を足しても拡張は事実行を黙って落とし(NDJSON は前方互換なので
// 落ちない = 気付けない)、needsProvisioningUpdate のズレは「GUI セッションで一度」の行が
// 消えて ssh から無限に再試行するループに戻る。stepStatusSync.test.mjs と同じ方式。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();

function swiftSource() {
  return readFileSync(
    path.join(ROOT, "..", "Sources", "FTBridgeClient", "XcodeSigningDiagnosis.swift"), "utf8");
}

/** enum XcodeSigningProblem の case 名を宣言順に集める */
function swiftProblemCases() {
  const source = swiftSource();
  const start = source.indexOf("enum XcodeSigningProblem");
  assert.ok(start >= 0, "XcodeSigningProblem が見つかりません");
  const body = source.slice(start, source.indexOf("var fact:", start));
  const found = [...body.matchAll(/^\s*case ([a-zA-Z]+)$/gm)].map((m) => m[1]);
  assert.ok(found.length > 0, "case を抽出できませんでした");
  return found;
}

/** needsProvisioningUpdate の `case .a, .b: return true` から true の集合を読む */
function swiftPortalCases() {
  const source = swiftSource();
  const start = source.indexOf("var needsProvisioningUpdate:");
  assert.ok(start >= 0, "needsProvisioningUpdate が見つかりません");
  const body = source.slice(start, start + 500);
  const match = body.match(/case ([^:]+): return true/);
  assert.ok(match, "return true の行を抽出できませんでした");
  return [...match[1].matchAll(/\.([a-zA-Z]+)/g)].map((m) => m[1]).sort();
}

function extensionSource() {
  return readFileSync(path.join(ROOT, "src", "monitorDeviceOps.ts"), "utf8");
}

/** SIGNING_FACT_KEYS のキー一覧 */
function tsFactKeys() {
  const source = extensionSource();
  const match = source.match(/const SIGNING_FACT_KEYS[^=]*=\s*\{([^}]+)\}/);
  assert.ok(match, "SIGNING_FACT_KEYS を抽出できませんでした");
  return [...match[1].matchAll(/^\s*([a-zA-Z]+):/gm)].map((m) => m[1]);
}

/** SIGNING_NEEDS_PORTAL の要素一覧 */
function tsPortalKinds() {
  const source = extensionSource();
  const match = source.match(/const SIGNING_NEEDS_PORTAL = new Set\(\[([^\]]+)\]/);
  assert.ok(match, "SIGNING_NEEDS_PORTAL を抽出できませんでした");
  return [...match[1].matchAll(/"([a-zA-Z]+)"/g)].map((m) => m[1]).sort();
}

test("署名種別: Swift の XcodeSigningProblem と拡張の SIGNING_FACT_KEYS が一致する", () => {
  assert.deepEqual(tsFactKeys(), swiftProblemCases());
});

test("署名種別: needsProvisioningUpdate と SIGNING_NEEDS_PORTAL が一致する", () => {
  assert.deepEqual(tsPortalKinds(), swiftPortalCases());
});
