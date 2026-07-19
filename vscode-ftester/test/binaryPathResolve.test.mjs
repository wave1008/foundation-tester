// binaryPathResolve の解決順テスト(clone 構成: 実在パス優先 / 外部パッケージ構成: PATH フォールバック)。
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { findFtesterOnPath, resolveBinaryPath } from "../src/binaryPathResolve.ts";

/** 実行可能な空の ftester を dir に作る。 */
function makeExecutable(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, "ftester");
  fs.writeFileSync(p, "#!/bin/sh\n");
  fs.chmodSync(p, 0o755);
  return p;
}

test("設定値(絶対)が実在すればそれを返す", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));
  const bin = makeExecutable(path.join(ws, ".build", "debug"));
  assert.equal(resolveBinaryPath(ws, bin), bin);
});

test("相対パスはワークスペースルート基準で解決し、実在すればそれを返す", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));
  makeExecutable(path.join(ws, ".build", "debug"));
  assert.equal(resolveBinaryPath(ws, ".build/debug/ftester"),
               path.join(ws, ".build/debug/ftester"));
});

test("設定値が不在なら PATH の ftester を返す(外部パッケージ構成)", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));  // .build/debug/ftester 無し
  const pathDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftpath-"));
  const onPath = makeExecutable(pathDir);
  const saved = process.env.PATH;
  try {
    process.env.PATH = pathDir;
    assert.equal(resolveBinaryPath(ws, ".build/debug/ftester"), onPath);
  } finally {
    process.env.PATH = saved;
  }
});

test("設定値も PATH も無ければ設定値をそのまま返す(既存エラー経路へ)", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));
  const emptyDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftempty-"));
  const saved = process.env.PATH;
  try {
    process.env.PATH = emptyDir;
    assert.equal(resolveBinaryPath(ws, ".build/debug/ftester"),
                 path.join(ws, ".build/debug/ftester"));
  } finally {
    process.env.PATH = saved;
  }
});

test("findFtesterOnPath は実行可能なものだけ拾い、非実行ファイルは無視する", () => {
  const execDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftx-"));
  const nonExecDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftn-"));
  fs.writeFileSync(path.join(nonExecDir, "ftester"), "x");  // 非実行
  fs.chmodSync(path.join(nonExecDir, "ftester"), 0o644);
  const onPath = makeExecutable(execDir);
  assert.equal(findFtesterOnPath(`${nonExecDir}${path.delimiter}${execDir}`), onPath);
});
