// install.sh のログ配線(tee)と再 exec の契約。
//
//   1. 再 exec された 2 周目は tee を立て直さない。`exec bash "$0"` はプロセス像を差し替える
//      だけで fd 1/2 は 1 周目の tee のパイプのまま(tee は同じ pid の子として生き続ける)。
//      2 本目の tee を挟むと、その stdout が 1 本目のパイプなので 2 周目の全行がログに 2 回入る。
//   2. 受け手向けの 4 スクリプトは実行文に `| head` を書かない(pipefail 下で上流が SIGPIPE を
//      受け、errexit のスクリプトは [fail] を 1 行も出さずに死ぬ。`awk 'NR<=N'` は入力を最後まで読む)。
//
// ログ配線のブロックを install.sh から抜き出し、再 exec の形だけを写した小さなスクリプトの中で
// 実行する(実装の写しを置かない —— 写すと本体だけ直したときにテストが古い実装を守り続ける)。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");

/** `LOG_FILE=""` から `exec > >(tee …)` を含む if ブロックの `fi` までを取り出す。 */
function logBlock() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const head = '\nLOG_FILE=""\nif [ -n "${FT_INSTALL_LOG:-}" ]; then\n';
  const begin = source.indexOf(head);
  assert.ok(begin > 0, "install.sh にログ配線のブロック(LOG_FILE= / FT_INSTALL_LOG)が無い");
  const end = source.indexOf("\nfi\n", begin);
  assert.ok(end > begin, "ログ配線ブロックの fi が見つからない");
  return source.slice(begin + 1, end + "\nfi\n".length);
}

/** 再 exec の形は本体と同じ 2 行であること(この写しが本体から乖離していないことの確認)。 */
function assertReexecShape() {
  const source = readFileSync(INSTALL_SH, "utf8");
  assert.ok(source.includes('export FT_REEXEC=1 FT_INSTALL_LOG="$LOG_FILE"'), "再 exec が FT_REEXEC / FT_INSTALL_LOG を渡していない");
  assert.ok(source.includes('exec bash "$0"'), "再 exec が exec bash \"$0\" でない");
}

/** ブロックを 2 周(1 周目 → 自分を再 exec → 2 周目)動かし、画面出力とログ本文を返す。 */
function runTwoPasses(block) {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-install-log-"));
  try {
    const script = path.join(dir, "two-pass.sh");
    writeFileSync(
      script,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'WORK_DIR="$1"',
        block,
        'echo "pass=${FT_REEXEC:-0}"',
        'if [ "${FT_REEXEC:-0}" != "1" ]; then',
        '  export FT_REEXEC=1 FT_INSTALL_LOG="$LOG_FILE"',
        '  exec bash "$0" "$1"',
        "fi",
        'echo "second-pass-line"',
        'echo "second-pass-stderr" >&2',
        "",
      ].join("\n"),
    );
    const res = spawnSync("bash", [script, dir], { encoding: "utf8" });
    assert.equal(res.status, 0, `2 周のスクリプトが落ちた: ${res.stderr}`);
    const logs = readdirSync(path.join(dir, ".fleetest")).filter((f) => /^install-.*\.log$/.test(f));
    assert.equal(logs.length, 1, `ログは 1 本のはず: ${logs.join(", ")}`);
    return { screen: res.stdout + res.stderr, log: readFileSync(path.join(dir, ".fleetest", logs[0]), "utf8") };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const count = (text, needle) => text.split("\n").filter((l) => l === needle).length;

test("再 exec の 2 周目でもログに各行は 1 回(1 周目の tee を継承し、立て直さない)", () => {
  assertReexecShape();
  const { screen, log } = runTwoPasses(logBlock());
  for (const line of ["pass=0", "pass=1", "second-pass-line", "second-pass-stderr"]) {
    assert.equal(count(log, line), 1, `ログに "${line}" が ${count(log, line)} 回(1 回のはず)\n--- log ---\n${log}`);
    assert.equal(count(screen, line), 1, `画面に "${line}" が ${count(screen, line)} 回(1 回のはず)`);
  }
});

test("破壊確認: 2 周目で tee を立て直すと 2 周目の行がログに 2 回入る(テスト自体の生存確認)", () => {
  const block = logBlock();
  const anchor = '  LOG_FILE="$FT_INSTALL_LOG"\n';
  assert.ok(block.includes(anchor), "2 周目の分岐に LOG_FILE=\"$FT_INSTALL_LOG\" が無い");
  const mutated = block.replace(anchor, `${anchor}  exec > >(tee -a "$LOG_FILE") 2>&1\n`);
  const { log } = runTwoPasses(mutated);
  assert.equal(count(log, "second-pass-line"), 2, "2 本目の tee を入れても重複しない = この検知は無力");
  assert.equal(count(log, "pass=0"), 1);
});

test("受け手向けスクリプトの実行文に `| head` が無い(pipefail 下の SIGPIPE)", () => {
  const offenders = [];
  for (const rel of ["Scripts/install.sh", "Scripts/align.sh", "Scripts/preflight.sh", "Scripts/mcp-server.sh"]) {
    const lines = readFileSync(path.join(ROOT, rel), "utf8").split("\n");
    lines.forEach((line, i) => {
      if (line.trim().startsWith("#")) return;
      if (/\|\s*head\b/.test(line)) offenders.push(`${rel}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [], "`| head` は上流を SIGPIPE で殺す。`awk 'NR<=N'` か文字列展開で 1 行目を取る");
});
