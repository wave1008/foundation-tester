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

// ---------------------------------------------------------------------------
// 以下は「対とリンク」ではなく **中身が実装とズレていないか** を落とす走査。
// 追加の経緯は docs/userDocs レビュー(8件)。いずれも1度は実際にズレていた。

const SOURCES = path.join(ROOT, "Sources");
const enPages = pages.filter((p) => !isJa(p));
const readPage = (p) => readFileSync(path.join(DOCS, p), "utf8");

// 英語ページに残ってよい日本語。**理由を書けないものは足さない** ——
// ここが伸びるのは翻訳漏れを追認しているとき。
const JA_IN_EN_ALLOWLIST = [
  // 参照先 vscode-ftester/README.md が日本語のみ。節を探すための原文なので訳すと辿れない
  { file: "running/results_analysis.md", text: "結果ダッシュボード" },
  { file: "running/parallel_execution.md", text: "並列実行とログレーン" },
  { file: "project/profiles.md", text: "実行プロファイルの編集支援" },
  // ja/en 両ロケールの端末に当てる例。日本語側を訳すと例が成立しない
  { file: "commands/ios_alert_handler.md", text: "トラッキング" },
  { file: "commands/ios_alert_handler.md", text: "許可" },
];

test("英語ページに翻訳漏れの日本語が無い", () => {
  const leaks = [];
  for (const page of enPages) {
    for (const line of readPage(page).split("\n")) {
      if (!/[぀-ヿ一-鿿]/.test(line)) continue;
      // 対のページへの言語切替リンク(「in Japanese(日本語)」)は日本語で書くのが正しい
      if (line.includes(`(${path.posix.basename(twinOf(page))})`)) continue;
      const allowed = JA_IN_EN_ALLOWLIST.some(
        (e) => e.file === page && line.includes(e.text));
      if (!allowed) leaks.push(`${page}: ${line.trim()}`);
    }
  }
  assert.deepEqual(leaks, [],
    `英語ページに日本語が残っている(拡張は i18n 済みなので UI 文字列は英語で引用する):\n  ${leaks.join("\n  ")}`);
});

test("英語ページが引用するコマンド名が package.nls.json に実在する", () => {
  const en = JSON.parse(readFileSync(path.join(process.cwd(), "package.nls.json"), "utf8"));
  const titles = new Set(Object.values(en));
  const unknown = [];
  for (const page of enPages) {
    // `ftester: X` 形(バッククォート内・引用符内どちらも)を拾う
    for (const m of readPage(page).matchAll(/["`](ftester: [^"`]+)["`]/g)) {
      if (!titles.has(m[1])) unknown.push(`${page}: "${m[1]}"`);
    }
  }
  assert.deepEqual(unknown, [],
    `package.nls.json に無いコマンド名を引用している(綴りが違うとパレットで見つからない):\n  ${unknown.join("\n  ")}`);
});

test("run_profile.md が実行プロファイルの全キーを列挙している", () => {
  // 正は RunProfile.swift の knownKeys(未知キー警告の判定に使う集合)。
  // ページ自身が「lists every recognized key」と謳っているので、等号で固定する。
  const swift = readFileSync(path.join(SOURCES, "FTCore", "RunProfile.swift"), "utf8");
  // knownKeys はこのファイルに7つある(app/machine/device/… 各プロファイル)。
  // 欲しいのは RunProfileDocument のものなので、その宣言以降で最初に出るものを採る
  const scope = swift.slice(swift.indexOf("public struct RunProfileDocument"));
  assert.ok(scope, "RunProfileDocument の宣言が見つからない");
  const block = scope.match(/static let knownKeys: Set<String> = \[([\s\S]*?)\]/);
  assert.ok(block, "RunProfileDocument の knownKeys を読めない(定義の形が変わった)");
  const known = [...block[1].matchAll(/"([a-zA-Z]+)"/g)].map((m) => m[1]).sort();

  for (const page of ["project/run_profile.md", "project/run_profile_ja.md"]) {
    const documented = [...readPage(page).matchAll(/^\| `([a-zA-Z]+)`/gm)].map((m) => m[1]).sort();
    assert.deepEqual([...new Set(documented)], [...new Set(known)],
      `${page} と RunProfile.knownKeys が食い違う(旧名 screenIs のような「まだ読まれるキー」も載せる)`);
  }
});

test("typed_selector.md が Sel の語彙を全部載せている", () => {
  // `.not(_)` が 2026-08-25 まで両言語とも抜けており、文字列版の `!=` から変換できなかった。
  const swift = readFileSync(path.join(SOURCES, "FTDSL", "Sel.swift"), "utf8");
  const api = [...swift.matchAll(/public (?:static )?func ([a-zA-Z]+)\(/g)].map((m) => m[1]);
  const vocabulary = [...new Set(api)].sort();
  assert.ok(vocabulary.includes("not"), "Sel.not が消えた(テストの前提が古い)");

  for (const page of ["selector/typed_selector.md", "selector/typed_selector_ja.md"]) {
    const source = readPage(page);
    const missing = vocabulary.filter((name) => !source.includes(`.${name}(`));
    assert.deepEqual(missing, [],
      `${page} に載っていない Sel のメソッド: ${missing.join(", ")}`);
  }
});
