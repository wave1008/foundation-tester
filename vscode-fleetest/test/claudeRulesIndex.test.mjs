// CLAUDE.md の領域固有の規律は `.claude/rules/<領域>.md`(パス限定の規則)にある
// (docs/maintainer-notes.md §52)。壊れても**黙る**形が2つあるので、ここで落とす:
//   ① CLAUDE.md の索引と実際の規則ファイルが食い違う(索引から辿れない規則・存在しない規則を指す索引)
//   ② 規則の `paths:` が実在のファイルに1つも当たらない —— Claude Code は書き誤ったパターンを
//      黙って無視するので、ファイルの改名でその規則が二度と読み込まれなくなっても誰も気づかない
// あわせて、AGENTS.md(Codex など向けの入口)が規則の本文を持たず CLAUDE.md へ誘導することを見る。

import assert from "node:assert/strict";
import { globSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const RULES = path.join(ROOT, ".claude/rules");
const ruleFiles = readdirSync(RULES).filter((f) => f.endsWith(".md")).sort();

function paths(file) {
  const text = readFileSync(path.join(RULES, file), "utf8");
  const fm = text.match(/^---\n([\s\S]*?)\n---\n/);
  assert.ok(fm, `${file} に frontmatter が無い`);
  return [...fm[1].matchAll(/^\s*-\s*"([^"]+)"/gm)].map((m) => m[1]);
}

test("CLAUDE.md の索引と .claude/rules/ の規則ファイルが一致する", () => {
  const claude = readFileSync(path.join(ROOT, "CLAUDE.md"), "utf8");
  const indexed = [...claude.matchAll(/`\.claude\/rules\/([a-z0-9-]+\.md)`/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(indexed)].sort(), ruleFiles);
});

test("規則ファイルの paths: は全部、実在のファイルに当たる(書き誤りは黙って無視されるため)", () => {
  const dead = [];
  for (const file of ruleFiles) {
    const list = paths(file);
    assert.ok(list.length > 0, `${file} に paths: が無い(全セッションで常に読み込まれてしまう)`);
    for (const pattern of list) {
      if (globSync(pattern, { cwd: ROOT }).length === 0) dead.push(`${file}: ${pattern}`);
    }
  }
  assert.deepEqual(dead, [], "実在のファイルに当たらないパターン(改名なら新しい名前へ直す)");
});

test("AGENTS.md は規則の本文を持たず、CLAUDE.md と規則ファイルへ誘導する", () => {
  const agents = readFileSync(path.join(ROOT, "AGENTS.md"), "utf8");
  assert.ok(agents.includes("CLAUDE.md"));
  assert.ok(agents.includes(".claude/rules/"));
  // 本文を写し始めたら膨らむ(規則は CLAUDE.md と規則ファイルの側にだけ置く)
  assert.ok(Buffer.byteLength(agents) < 4096, `AGENTS.md が ${Buffer.byteLength(agents)} バイトある`);
});
