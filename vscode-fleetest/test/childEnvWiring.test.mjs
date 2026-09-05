// childEnvWiring.test.mjs
// 拡張が起こす全子プロセス(spawn/execFile/exec/fork)が env: childEnv() を渡していることの
// ソース走査(src/childEnv.ts 参照)。渡し忘れは「拡張の突然死で孤児になる」という沈黙の欠陥
// (Codex 指摘 2026-09-05)なので、新しい spawn を足したときに機械で落とす。

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const SRC_DIR = path.join(process.cwd(), "src");
// 呼び出し開始からこの行数以内に env: childEnv() があればよい(監査済み:現在の全呼び出しは
// オプションオブジェクトをこの範囲内で閉じている。新しい呼び出しがこれを超えて分割されたら
// 目視で確認し、必要ならこの定数を広げる)。
const WINDOW_LINES = 12;
// `spawn(` / `execFile(` / `exec(` / `fork(` の直呼び出しだけを拾う(前が `.` や単語文字だと
// `classRe.exec(...)` のような RegExp メソッド呼び出しや `spawnFn(` を誤検知するので除外)。
const CALL_RE = /(?<![.\w])(spawn|execFile|exec|fork)\(/g;

/** ブロックコメント・行コメントを空白に落とす(行番号はそのまま保つ)。 */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, " "))
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

function listTsFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...listTsFiles(full));
    } else if (entry.name.endsWith(".ts")) {
      out.push(full);
    }
  }
  return out;
}

/** source 中の child_process 呼び出しのうち、直後 WINDOW_LINES 行以内に env: childEnv() が
 * 現れないものを "label:line" の形で返す。総呼び出し数も併せて返す(空振り検知用)。 */
function findViolations(source, label) {
  const lines = stripComments(source).split("\n");
  const violations = [];
  let total = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*import\b/.test(line)) {
      continue;
    }
    CALL_RE.lastIndex = 0;
    while (CALL_RE.exec(line)) {
      total++;
      const windowText = lines.slice(i, i + WINDOW_LINES + 1).join("\n");
      if (!windowText.includes("childEnv(")) {
        violations.push(`${label}:${i + 1}: ${line.trim()}`);
      }
    }
  }
  return { total, violations };
}

test("src/**/*.ts の全 spawn/execFile/exec/fork 呼び出しは env: childEnv() を渡す", () => {
  const violations = [];
  let total = 0;
  for (const file of listTsFiles(SRC_DIR)) {
    const rel = path.relative(process.cwd(), file);
    const result = findViolations(readFileSync(file, "utf8"), rel);
    total += result.total;
    violations.push(...result.violations);
  }
  assert.deepEqual(
    violations,
    [],
    "FT_PARENT_PID が無いと、拡張ホストの突然死でこの子プロセスが孤児になります" +
      "(src/childEnv.ts の childEnv() を options に env: childEnv() として渡してください):\n" +
      violations.join("\n"),
  );
  // 陽性対照: この走査が実際に呼び出しを見つけているか(0件なら上のテストは常に緑で歯止めにならない)。
  assert.ok(total >= 20, `spawn 系呼び出しの検出数が少なすぎます(${total}件)`);
});

test("検知ロジック自体が壊れていない(合成ソースでの陽性/陰性)", () => {
  const missing = findViolations(
    ['proc = spawn(bin, args, {', "  cwd: x,", '  stdio: ["ignore", "pipe", "pipe"],', "});"].join("\n"),
    "synthetic",
  );
  assert.equal(missing.total, 1);
  assert.equal(missing.violations.length, 1, "childEnv() が無い spawn は検出されるべき");

  const wired = findViolations(
    'proc = spawn(bin, args, { env: childEnv(), stdio: ["ignore", "pipe", "pipe"] });',
    "synthetic",
  );
  assert.equal(wired.total, 1);
  assert.equal(wired.violations.length, 0, "childEnv() 付きの spawn は誤検知してはいけない");

  const importLine = findViolations('import { spawn } from "node:child_process";', "synthetic");
  assert.equal(importLine.total, 0, "import 行は呼び出しと数えてはいけない");

  const regexExec = findViolations("const m = classRe.exec(text);", "synthetic");
  assert.equal(regexExec.total, 0, "RegExp#exec は child_process の exec と誤検知してはいけない");

  const spawnFnCall = findViolations("proc = this.spawnFn(bin, args, {});", "synthetic");
  assert.equal(spawnFnCall.total, 0, "spawnFn(独自ラッパ)は spawn( と誤検知してはいけない");

  const commentedOut = findViolations("// spawn(bin, args, {})", "synthetic");
  assert.equal(commentedOut.total, 0, "コメント中の spawn( は呼び出しと数えてはいけない");
});
