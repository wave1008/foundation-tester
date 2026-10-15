// binaryPathResolve の解決順テスト(clone 構成: 実在パス優先 / 外部パッケージ構成: PATH フォールバック)。
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { binaryDirs, findFleetestOnPath, realBinaryPath, resolveBinaryPath } from "../src/binaryPathResolve.ts";

/** 実行可能な空の fleetest を dir に作る。 */
function makeExecutable(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, "fleetest");
  fs.writeFileSync(p, "#!/bin/sh\n");
  fs.chmodSync(p, 0o755);
  return p;
}

test("設定値(絶対)が実在すればそれを返す", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));
  const bin = makeExecutable(path.join(ws, ".build", "debug"));
  assert.equal(resolveBinaryPath(ws, bin), fs.realpathSync(bin));
});

test("相対パスはワークスペースルート基準で解決し、実在すればそれを返す", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));
  makeExecutable(path.join(ws, ".build", "debug"));
  assert.equal(resolveBinaryPath(ws, ".build/debug/fleetest"),
               fs.realpathSync(path.join(ws, ".build/debug/fleetest")));
});

test("設定値が不在なら PATH の fleetest を返す(外部パッケージ構成)", () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-"));  // .build/debug/fleetest 無し
  const pathDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftpath-"));
  const onPath = makeExecutable(pathDir);
  const saved = process.env.PATH;
  try {
    process.env.PATH = pathDir;
    assert.equal(resolveBinaryPath(ws, ".build/debug/fleetest"), fs.realpathSync(onPath));
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
    assert.equal(resolveBinaryPath(ws, ".build/debug/fleetest"),
                 path.join(ws, ".build/debug/fleetest"));
  } finally {
    process.env.PATH = saved;
  }
});

test("findFleetestOnPath は実行可能なものだけ拾い、非実行ファイルは無視する", () => {
  const execDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftx-"));
  const nonExecDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftn-"));
  fs.writeFileSync(path.join(nonExecDir, "fleetest"), "x");  // 非実行
  fs.chmodSync(path.join(nonExecDir, "fleetest"), 0o644);
  const onPath = makeExecutable(execDir);
  assert.equal(findFleetestOnPath(`${nonExecDir}${path.delimiter}${execDir}`), onPath);
});

// .build/debug は SwiftPM がビルドのたびに消して作り直すリンク。その間(実測 約 0.8ms)リンク経由の spawn が ENOENT になるので、
// 起動には実体を使い、プロセスの見分けには実体とリンクの両方の置き場を使う(2026-10-15 の負荷テスト)
test("リンクを経た設定値は実体へ解決し、見分けの置き場は両方を返す", () => {
  const ws = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ftbp-")));
  const real = makeExecutable(path.join(ws, ".build", "out", "Products", "Debug"));
  fs.symlinkSync(path.join(ws, ".build", "out", "Products", "Debug"), path.join(ws, ".build", "debug"));
  const resolved = resolveBinaryPath(ws, ".build/debug/fleetest");
  assert.equal(resolved, real);
  assert.deepEqual(binaryDirs(resolved), [path.dirname(real), path.join(ws, ".build", "debug")]);
  // リンクが一時的に無い(作り直しの最中)でも、通常の入口が覚えた実体を返す —— PATH に別の fleetest があっても切り替わらない
  fs.unlinkSync(path.join(ws, ".build", "debug"));
  const pathDir = fs.mkdtempSync(path.join(os.tmpdir(), "ftpath-"));
  makeExecutable(pathDir);
  const saved = process.env.PATH;
  try {
    process.env.PATH = pathDir;
    assert.equal(resolveBinaryPath(ws, ".build/debug/fleetest"), real);
  } finally {
    process.env.PATH = saved;
  }
  assert.equal(realBinaryPath(path.join(ws, ".build/debug/fleetest")), real);
});

test("解決できないパスは元のまま返す", () => {
  const missing = path.join(os.tmpdir(), "ftbp-absent", "fleetest");
  assert.equal(realBinaryPath(missing), missing);
});
