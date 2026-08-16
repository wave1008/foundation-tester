// ArgumentParser の `help:` に**連結した String を渡していない**ことの検証(Swift ソース走査)。
//
// なぜ node 側にあるか: Swift 側は「コンパイルが通らない」形の誤りなので単体テストでは表現できず、
// かつ **swift build を1回払わないと気付けない**。ソース走査なら数十ミリ秒で落ちる
// (同型の走査テストが npm test 側にある: preflightRunnerMode.test.mjs / installStepSync.test.mjs)。
//
// 契約: `ArgumentHelp` は **ExpressibleByStringLiteral** なので `help: "…"` は通るが、
// `help: "…" + "…"`(String に評価される式)は通らない。長い説明は `ArgumentHelp("…" + "…")` で包む。
// このリポジトリでは同じ誤りを**4回**踏んでおり(2026-08-16〜17)、そのたびにビルドが1回無駄になった。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const SOURCES = ["Sources/ftester", "Sources/ftester-mcp"];

/** `help:` に続く実引数が「文字列リテラルの連結」になっている箇所を返す(ArgumentHelp( で包めば対象外)。 */
function findConcatenatedHelp(source) {
  const hits = [];
  // help: "…"(改行含む) の直後に + が続く形。ArgumentHelp( が直前にあるものは除く
  // `ArgumentHelp(` で包んだ形だけを除外する。**素の括弧 `help: ("a" + "b")` は対象**
  // —— これも String に評価されるのでコンパイルが通らない(変異テストで見つけた穴)
  const pattern = /help:\s*(ArgumentHelp\s*\()?\s*\(?\s*"(?:[^"\\]|\\.)*"\s*\n?\s*\+/g;
  for (const match of source.matchAll(pattern)) {
    if (match[1]) continue; // ArgumentHelp( で包まれている
    hits.push(source.slice(match.index, match.index + 80).split("\n")[0]);
  }
  return hits;
}

test("ArgumentParser の help: に連結した String を渡していない(ArgumentHelp で包む)", () => {
  const offenders = [];
  for (const dir of SOURCES) {
    const abs = path.join(ROOT, dir);
    let entries;
    try {
      entries = readdirSync(abs).filter((name) => name.endsWith(".swift"));
    } catch {
      continue; // ディレクトリが無い構成でも走査テスト自体は落とさない
    }
    for (const name of entries) {
      const source = readFileSync(path.join(abs, name), "utf8");
      for (const line of findConcatenatedHelp(source)) {
        offenders.push(`${dir}/${name}: ${line}`);
      }
    }
  }
  assert.deepEqual(
    offenders,
    [],
    "help: に連結した String を渡しています(ArgumentHelp は文字列リテラルからしか作れないため" +
      "コンパイルが通りません)。ArgumentHelp(\"…\" + \"…\") で包んでください:\n" + offenders.join("\n"),
  );
});

test("検知が効いている(包んでいない形を作れば落ちる)", () => {
  // 陽性対照: 常に空を返す実装に退化していないか
  const bad = `@Option(help: "long text "\n        + "continued")\nvar x: String?`;
  assert.equal(findConcatenatedHelp(bad).length, 1);
  const parenthesized = `@Option(help: ("long text "\n        + "continued"))\nvar x: String?`;
  assert.equal(findConcatenatedHelp(parenthesized).length, 1);
  const good = `@Option(help: ArgumentHelp("long text "\n        + "continued"))\nvar x: String?`;
  assert.equal(findConcatenatedHelp(good).length, 0);
});
