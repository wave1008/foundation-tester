// 拡張が `--skip-build` を付けて呼ぶ `fleetest api <sub>` は、Swift 側でそのフラグを宣言していること。
// 宣言の無いサブコマンドへ渡すと ArgumentParser が未知の引数で落とし、拡張は JSON が読めないとだけ記録する
// (validate-profile がこの形で、設定 buildBeforeRun を OFF にした利用者ではプロファイルの検証が毎回失敗していた)。
// 呼び出しの組み立ては src/*.ts の `["api", "<sub>", …]` と同じ関数内の `"--skip-build"` で拾う。
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");
const SRC = path.join(ROOT, "src");
const SWIFT_DIR = path.join(REPO, "Sources/fleetest");

/** commandName ごとに、その型の本体(次の commandName まで)に skipBuild の宣言があるか。 */
function swiftSubcommandsWithSkipBuild() {
  const result = new Map();
  for (const name of readdirSync(SWIFT_DIR).filter((f) => f.endsWith(".swift"))) {
    const text = readFileSync(path.join(SWIFT_DIR, name), "utf8");
    const marks = [...text.matchAll(/commandName:\s*"([^"]+)"/g)];
    marks.forEach((m, i) => {
      const end = i + 1 < marks.length ? marks[i + 1].index : text.length;
      const body = text.slice(m.index, end);
      const has = /customLong\("skip-build"\)|var skipBuild\b/.test(body);
      result.set(m[1], (result.get(m[1]) ?? false) || has);
    });
  }
  return result;
}

/** src の各ファイルで、`"--skip-build"` を積む箇所の直前にある `["api", "<sub>"` を拾う。 */
function extensionSkipBuildCallers() {
  const callers = [];
  for (const name of readdirSync(SRC).filter((f) => f.endsWith(".ts"))) {
    const text = readFileSync(path.join(SRC, name), "utf8");
    for (const m of text.matchAll(/"--skip-build"/g)) {
      const before = text.slice(0, m.index);
      const api = [...before.matchAll(/\[\s*"api",\s*"([a-z-]+)"/g)].pop();
      if (api) callers.push({ file: name, sub: api[1] });
    }
  }
  return callers;
}

test("拡張が --skip-build を渡す api サブコマンドは、Swift 側でそのフラグを宣言している", () => {
  const swift = swiftSubcommandsWithSkipBuild();
  const callers = extensionSkipBuildCallers();
  assert.ok(callers.length >= 3, `走査が呼び出しに届いていない(${callers.length} 件)`);
  assert.ok(swift.size > 10, "走査が Sources/fleetest に届いていない");
  const missing = callers.filter((c) => swift.get(c.sub) !== true).map((c) => `${c.file}: api ${c.sub}`);
  assert.deepEqual(missing, [], "--skip-build を持たないサブコマンドへ渡している");
});
