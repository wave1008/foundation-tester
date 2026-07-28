// package.json と package-lock.json の version 一致検査。
//
// なぜ要るか: lock は package.json の version を2箇所に内包する。版上げのときに lock を更新し
// 忘れると、受け手の `npm install` が version 行だけを書き換えてクローンが dirty になり、
// **次の更新が install.sh の pull ガードで止まる**(2026-07-29 に受け手が踏んだ)。
// 版上げは `npm version --no-git-tag-version <ver>` で行えば両方揃う(CLAUDE.md)。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const read = (name) => JSON.parse(readFileSync(path.join(ROOT, name), "utf8"));

test("版: package.json と package-lock.json の version が一致する", () => {
  const pkg = read("package.json");
  const lock = read("package-lock.json");
  const hint =
    ` package.json を上げたら lock も上げてください:` +
    ` npm version --no-git-tag-version ${pkg.version}(両方まとめて書き換わります)。`;

  assert.equal(lock.version, pkg.version, `package-lock.json の version がズレています。${hint}`);
  assert.equal(
    lock.packages?.[""]?.version,
    pkg.version,
    `package-lock.json の packages[""].version がズレています。${hint}`,
  );
});
