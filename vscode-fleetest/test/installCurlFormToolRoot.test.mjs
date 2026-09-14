// install.sh の TOOL_ROOT 解決(ステップ0.5)が curl 形(`curl … | bash -s --`)でも
// preflight.sh/update.sh/toolRootResolve.ts と同じ規則(既定の隣より Package.swift の
// .package(path:) 宣言を優先する)に従うことの回帰テスト。
//
// 実害: install.sh は SELF_ROOT(BASH_SOURCE[0] がファイルであること = on-disk 実行)が
// 取れないとき、Package.swift の宣言を見ずにいきなり既定の隣(../foundation-tester)へ倒していた。
// curl 形(BASH_SOURCE[0] が空になる)では常にこの経路を通るため、`--tool-root <custom>` で
// 導入済みの受け手が引数無しで curl 形を再実行すると、既存のクローンを無視して
// 別の場所へ新しく clone しようとしていた(docs/bug-audit-2026-09-06.md §3)。
//
// 本体を丸ごとは実行しない(clone/swift build を伴い重い上にネットワークが要る)。
// TOOL_ROOT 解決ブロックだけを文字列で切り出し、`bash -s --`(標準入力からの実行 = BASH_SOURCE[0]
// が空になり curl 形を再現する)/ 実ファイル実行(on-disk 形)の両方で走らせて解決結果を見る
// (installDivergedClone.test.mjs と同じ「実装の写しを置かない」方針)。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");

/** TOOL_ROOT_ARG/SELF_ROOT/DECLARED_ROOT の判定〜TOOL_ROOT_RAW の確定までを切り出す。 */
function toolRootBlock() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const start = source.indexOf("# ---- 0.5 TOOL_ROOT(");
  assert.ok(start > 0, "install.sh の TOOL_ROOT 解決ブロックが見つからない(走査の前提が崩れた)");
  const end = source.indexOf('\nif [ -d "$TOOL_ROOT_RAW/.git"', start);
  assert.ok(end > start, "TOOL_ROOT 解決ブロックの終端が見つからない");
  return source.slice(start, end);
}

/** dir を(判定に使う)最小のクローンにする: Package.swift + Sources/FTScenarioRunner/。 */
function makeCloneMarker(dir) {
  mkdirSync(path.join(dir, "Sources", "FTScenarioRunner"), { recursive: true });
  writeFileSync(path.join(dir, "Package.swift"), "// stub clone\n");
}

/** curl 形(標準入力からの bash -s --。BASH_SOURCE[0] は空)でブロックを実行し、
 * 解決された TOOL_ROOT_RAW を返す。 */
function resolveCurlForm({ workDir, toolRootArg = "" }) {
  const script = [
    `TOOL_ROOT_ARG=${JSON.stringify(toolRootArg)}`,
    `WORK_DIR=${JSON.stringify(workDir)}`,
    toolRootBlock(),
    'printf \'%s\' "$TOOL_ROOT_RAW"',
  ].join("\n");
  const res = spawnSync("bash", ["-s", "--"], { input: script, encoding: "utf8" });
  assert.equal(res.status, 0, `resolution block failed (status=${res.status}): ${res.stderr}`);
  return res.stdout;
}

/** on-disk 形(実ファイルを bash <file> で実行。BASH_SOURCE[0] はそのファイル)で実行する。
 * selfCloneDir/Scripts/install.sh へブロックを書き出して実行する(SELF_ROOT の判定が
 * `dirname/..` を見るため、実際に Scripts/ の下に置く必要がある)。 */
function resolveOnDiskForm({ selfCloneDir, workDir, toolRootArg = "" }) {
  makeCloneMarker(selfCloneDir);
  const scriptsDir = path.join(selfCloneDir, "Scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const scriptPath = path.join(scriptsDir, "install.sh");
  const script = [
    "#!/bin/bash",
    `TOOL_ROOT_ARG=${JSON.stringify(toolRootArg)}`,
    `WORK_DIR=${JSON.stringify(workDir)}`,
    toolRootBlock(),
    'printf \'%s\' "$TOOL_ROOT_RAW"',
  ].join("\n");
  writeFileSync(scriptPath, script);
  const res = spawnSync("bash", [scriptPath], { encoding: "utf8" });
  assert.equal(res.status, 0, `resolution block failed (status=${res.status}): ${res.stderr}`);
  return res.stdout;
}

let base;
function freshBase() {
  base = mkdtempSync(path.join(tmpdir(), "ft-install-toolroot-"));
  return base;
}

test("curl 形: WORK_DIR/Package.swift が宣言する既存 TOOL_ROOT を既定の隣より優先する", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const customToolRoot = path.join(dir, "custom-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(customToolRoot);
  // 相対パス宣言(実際の install.sh が書く形と同じ)。既定の隣は作らない。
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../custom-tool-root")\n');

  const resolved = resolveCurlForm({ workDir });
  // install.sh は宣言をそのまま WORK_DIR に連結するだけで正規化しない(abspath は後段の役目)。
  assert.equal(resolved, `${workDir}/../custom-tool-root`);
});

test("curl 形: --tool-root 明示は Package.swift の宣言より優先される", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const declaredToolRoot = path.join(dir, "declared-tool-root");
  const explicitToolRoot = path.join(dir, "explicit-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(declaredToolRoot);
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../declared-tool-root")\n');

  const resolved = resolveCurlForm({ workDir, toolRootArg: explicitToolRoot });
  assert.equal(resolved, explicitToolRoot);
});

test("curl 形: 宣言も既存クローンも無ければ既定の隣へ倒す(フォールバックは維持)", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  mkdirSync(workDir, { recursive: true }); // Package.swift 無し

  const resolved = resolveCurlForm({ workDir });
  assert.equal(resolved, `${workDir}/../foundation-tester`);
});

test("on-disk 形: 自分自身(SELF_ROOT)が Package.swift の宣言より優先される", (t) => {
  const dir = freshBase();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const workDir = path.join(dir, "receiver");
  const selfCloneDir = path.join(dir, "self-clone");
  const declaredToolRoot = path.join(dir, "declared-tool-root");
  mkdirSync(workDir, { recursive: true });
  makeCloneMarker(declaredToolRoot);
  writeFileSync(path.join(workDir, "Package.swift"), '.package(path: "../declared-tool-root")\n');

  const resolved = resolveOnDiskForm({ selfCloneDir, workDir });
  assert.equal(resolved, selfCloneDir);
});
