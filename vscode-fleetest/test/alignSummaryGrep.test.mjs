// align.sh の集計ループ(機械ごとの ✅/❌ 行)が、ログに 1 件も拾える行が無くても最後まで走る契約。
//
// `line=$(grep … | tail -1)` は `set -euo pipefail` の下で grep が 0 件だと代入ごと失敗し、
// 集計を出す前にスクリプトが落ちて EXIT trap が LOGDIR を消していた(ログが失われる)。
// 守るのは `|| true` の 1 つだけなので、ループ本体を align.sh から抜き出してそのまま実行する
// (実装の写しを置かない —— 写すと本体だけ直したときにテストが古い実装を守り続ける)。
//
// 注意: ループは失敗した機械のログを `/tmp/align-<machine>.log` へ写す(本体の仕様)。
// テストは一意な機械名を使い、finally で消す。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const ALIGN_SH = path.join(ROOT, "Scripts/align.sh");

/** `FAILED=0` から集計ループの `done` までを取り出す。 */
function summaryLoop() {
  const source = readFileSync(ALIGN_SH, "utf8");
  const begin = source.indexOf("\nFAILED=0\nfor m in $MACHINES; do\n");
  assert.ok(begin > 0, "align.sh に集計ループ(FAILED=0 / for m in $MACHINES)が無い");
  const end = source.indexOf("\ndone\n", begin);
  assert.ok(end > begin, "集計ループの done が見つからない");
  return source.slice(begin + 1, end + "\ndone\n".length);
}

/**
 * 集計ループを `set -euo pipefail` の下で実行する。machines は { name: { log, code } }。
 * ループの後にマーカー行を出し、そこまで到達したかで「途中で落ちていない」を見る。
 */
function runLoop(snippet, machines) {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-align-summary-"));
  const logDir = path.join(dir, "logs");
  mkdirSync(logDir);
  const names = Object.keys(machines);
  try {
    for (const [name, { log, code }] of Object.entries(machines)) {
      writeFileSync(path.join(logDir, `${name}.log`), log);
      writeFileSync(path.join(logDir, `${name}.code`), `${code}\n`);
    }
    const script = path.join(dir, "loop.sh");
    writeFileSync(
      script,
      [
        "set -euo pipefail",
        `MACHINES="${names.join(" ")}"`,
        `LOGDIR="${logDir}"`,
        snippet,
        'echo "SUMMARY_DONE FAILED=$FAILED"',
        "",
      ].join("\n"),
    );
    const res = spawnSync("bash", [script], { encoding: "utf8" });
    return { stdout: res.stdout, status: res.status };
  } finally {
    rmSync(dir, { recursive: true, force: true });
    for (const name of names) rmSync(`/tmp/align-${name}.log`, { force: true });
  }
}

const suffix = `${process.pid}-${Date.now()}`;

test("grep が 0 件の機械があっても集計は最後まで出る(✅ も ❌ も)", () => {
  const ok = `fttest-ok-${suffix}`;
  const silent = `fttest-silent-${suffix}`;
  const failed = `fttest-fail-${suffix}`;
  const { stdout, status } = runLoop(summaryLoop(), {
    [ok]: { log: "fetching…\naligned to 0123abc\n", code: 0 },
    [silent]: { log: "(remote printed nothing useful)\n", code: 0 },
    [failed]: { log: "ssh: connection timed out\n", code: 255 },
  });
  assert.equal(status, 0, `ループが途中で落ちた:\n${stdout}`);
  assert.match(stdout, new RegExp(`✅ ${ok}: aligned to 0123abc`));
  assert.match(stdout, new RegExp(`✅ ${silent}: \\(出力なし\\)`), "0 件のときの (出力なし) 行が出ていない");
  assert.match(stdout, new RegExp(`❌ ${failed}: \\(出力なし\\) \\(exit=255`));
  assert.match(stdout, /^SUMMARY_DONE FAILED=1$/m, "集計の後ろまで到達していない");
});

test("破壊確認: `|| true` を外すと 0 件の機械で集計が止まる(テスト自体の生存確認)", () => {
  const snippet = summaryLoop();
  const guarded = /line=\$\(grep [^\n]*\| tail -1 \|\| true\)/;
  assert.match(snippet, guarded, "align.sh の grep 行に `|| true` が無い(修正が消えた?)");
  const mutated = snippet.replace(guarded, (m) => m.replace(" || true)", ")"));
  assert.notEqual(mutated, snippet);
  const silent = `fttest-mut-${suffix}`;
  const { stdout, status } = runLoop(mutated, { [silent]: { log: "nothing matches\n", code: 0 } });
  assert.notEqual(status, 0, "`|| true` 無しでも落ちない = この検知は無力");
  assert.doesNotMatch(stdout, /SUMMARY_DONE/);
});
