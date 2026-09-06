// Scripts/preflight.sh 既定モードの `--work-dir <dir>` の契約。
//
//   1. `--work-dir <dir>` は `cd <dir>` して実行したときと **出力も exit code も同一**
//      (usage が宣伝していたのに既定モードでは無視され、常にカレントを判定していた)。
//   2. フラグ無しの経路は `WORK_DIR="$PWD"` のまま(既定モードの出力は 1 バイトも変えない契約)。
//   3. 無いディレクトリは判定できないので exit 1(blocked と同じ)で、理由を stderr に出す。
//
// 実マシンの状態(Xcode 等)に依存する行があるので値は断定せず、2 経路の同一性だけを見る。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const PREFLIGHT_SH = path.join(ROOT, "Scripts/preflight.sh");

test("--work-dir <dir> は cd <dir> と同じ判定を出す(stdout と exit code が一致)", () => {
  // tmpdir() は /var/folders(シンボリックリンク)。cd 経由の $PWD と `cd && pwd` を揃えるため
  // 物理パスに解決してから両方に渡す
  const dir = path.join(mkdtempSync(path.join(tmpdir(), "ft-preflight-wd-")), "app-tests");
  const physical = spawnSync("bash", ["-c", 'mkdir -p "$1" && cd "$1" && pwd -P', "_", dir], { encoding: "utf8" }).stdout.trim();
  try {
    const viaFlag = spawnSync("bash", [PREFLIGHT_SH, "--work-dir", physical], { cwd: ROOT, encoding: "utf8" });
    const viaCd = spawnSync("bash", [PREFLIGHT_SH], { cwd: physical, encoding: "utf8" });
    assert.equal(viaFlag.status, viaCd.status, `exit code が違う: --work-dir=${viaFlag.status} / cd=${viaCd.status}`);
    assert.equal(viaFlag.stdout, viaCd.stdout, "--work-dir と cd で出力が違う");
    assert.match(viaFlag.stdout, new RegExp(`^work_dir=${physical.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"));
    assert.match(viaFlag.stdout, /^folder_name=app-tests$/m);
    assert.match(viaFlag.stdout, /^verdict=(ready|installed|blocked)$/m);
  } finally {
    rmSync(path.dirname(dir), { recursive: true, force: true });
  }
});

test("--work-dir に無いディレクトリを渡すと exit 1 で理由を stderr に出す", () => {
  const missing = path.join(tmpdir(), `ft-preflight-missing-${process.pid}`);
  const res = spawnSync("bash", [PREFLIGHT_SH, "--work-dir", missing], { cwd: ROOT, encoding: "utf8" });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /--work-dir does not exist/);
  assert.equal(res.stdout, "", "判定できないのに key=value を出している");
});

test("フラグ無しの経路は WORK_DIR=\"$PWD\" のまま(既定モードの出力は 1 バイトも変えない)", () => {
  const source = readFileSync(PREFLIGHT_SH, "utf8");
  assert.match(source, /^else\n  WORK_DIR="\$PWD"\nfi$/m, "フラグ無しのときの WORK_DIR=\"$PWD\" が消えた");
  assert.match(source, /--work-dir\)/, "--work-dir を case 分岐で受け付けていない");
});
