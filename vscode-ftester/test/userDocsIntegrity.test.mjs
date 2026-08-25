// docs/userDocs/(利用者向けドキュメント。Shirates 流の en/ja 対)の整合検証。
// 契約(CLAUDE.md「ドキュメント」): 1ページ = `<name>.md`(英)+ `<name>_ja.md`(日)の対。
// 片方だけ足す・片方だけ消すと対が崩れ、index から辿れない孤児や切れたリンクが残るので、
// ソース走査で秒未満に落とす(ビルドもデバイスも要らない)。
//
// 見るのは4つ: ①対の存在 ②相対リンク先の実在 ③言語の一貫性(ja ページは ja ページへ、en は en へ)
// ④index.md / index_ja.md への掲載と、各ページから index へ戻るリンク。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const DOCS = path.join(ROOT, "docs", "userDocs");

/** docs/userDocs 配下の .md を再帰で集める(DOCS からの相対パス、"/" 区切り)。 */
function listPages(dir = DOCS) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...listPages(full));
    else if (entry.endsWith(".md")) out.push(path.relative(DOCS, full).split(path.sep).join("/"));
  }
  return out.sort();
}

const isJa = (p) => p.endsWith("_ja.md");
const twinOf = (p) => (isJa(p) ? p.replace(/_ja\.md$/, ".md") : p.replace(/\.md$/, "_ja.md"));

/** 本文中の相対 Markdown リンク先(`](target)`)。外部 URL・アンカーのみは除外。 */
function relativeLinks(source) {
  const targets = [];
  // コードブロック内の `](…)` は本文ではないので除く
  const body = source.replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
  for (const m of body.matchAll(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    const raw = m[1];
    if (/^(https?:|mailto:|#)/.test(raw)) continue;
    targets.push(raw.replace(/#.*$/, ""));
  }
  return targets;
}

const pages = listPages();

test("docs/userDocs にページがある", () => {
  assert.ok(pages.includes("index.md") && pages.includes("index_ja.md"),
    "index.md / index_ja.md が docs/userDocs に無い");
  assert.ok(pages.length > 2, "docs/userDocs にページが無い");
});

test("全ページに en/ja の対がある", () => {
  const set = new Set(pages);
  const orphans = pages.filter((p) => !set.has(twinOf(p)));
  assert.deepEqual(orphans, [],
    `対(${isJa(orphans[0] ?? "") ? ".md" : "_ja.md"})が無いページ: ${orphans.join(", ")}`);
});

test("相対リンク先が実在し、言語が一貫している", () => {
  const broken = [];
  const crossLanguage = [];
  for (const page of pages) {
    const source = readFileSync(path.join(DOCS, page), "utf8");
    const fromDir = path.dirname(path.join(DOCS, page));
    for (const target of relativeLinks(source)) {
      const resolved = path.resolve(fromDir, target);
      if (!existsSync(resolved)) {
        broken.push(`${page} -> ${target}`);
        continue;
      }
      // docs/userDocs 内のページ同士は言語を揃える(自分の対へのリンクだけは言語切替として許す)
      const inside = path.relative(DOCS, resolved);
      if (inside.startsWith("..") || !inside.endsWith(".md")) continue;
      const rel = inside.split(path.sep).join("/");
      if (rel === twinOf(page)) continue;
      if (isJa(page) !== isJa(rel)) crossLanguage.push(`${page} -> ${target}`);
    }
  }
  assert.deepEqual(broken, [], `リンク先が存在しない: \n  ${broken.join("\n  ")}`);
  assert.deepEqual(crossLanguage, [],
    `ja ページは _ja.md へ、en ページは .md へリンクする: \n  ${crossLanguage.join("\n  ")}`);
});

test("index に全ページが載り、各ページから index へ戻れる", () => {
  const indexEn = readFileSync(path.join(DOCS, "index.md"), "utf8");
  const indexJa = readFileSync(path.join(DOCS, "index_ja.md"), "utf8");
  const listedEn = new Set(relativeLinks(indexEn));
  const listedJa = new Set(relativeLinks(indexJa));

  const unlisted = [];
  const noWayBack = [];
  for (const page of pages) {
    if (page === "index.md" || page === "index_ja.md") continue;
    const listed = isJa(page) ? listedJa : listedEn;
    if (!listed.has(page)) unlisted.push(page);

    const source = readFileSync(path.join(DOCS, page), "utf8");
    const fromDir = path.dirname(path.join(DOCS, page));
    const indexName = isJa(page) ? "index_ja.md" : "index.md";
    const linksToIndex = relativeLinks(source).some(
      (t) => path.resolve(fromDir, t) === path.join(DOCS, indexName));
    if (!linksToIndex) noWayBack.push(page);
  }
  assert.deepEqual(unlisted, [], `index に載っていないページ: ${unlisted.join(", ")}`);
  assert.deepEqual(noWayBack, [], `index へのリンクが無いページ: ${noWayBack.join(", ")}`);
});
