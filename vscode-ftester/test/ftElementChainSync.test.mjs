// FTElement のチェーン網羅の同期検査。
// 契約(Sources/FTDSL/Commands.swift の FTElement コメント): セレクタを取り「その要素」を
// 検証する自由関数は、すべて同名で FTElement にも生える。一部だけ生やすと
// 「どれがチェーンできるか」が覚えられず、書いてみるまで分からない状態になる。
//
// 一方向の検査(検証系の自由関数 → FTElement)。逆(FTElement にあって自由関数に無い)は
// 見ない: idIs のようにチェーン専用の検証があり得るため。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const COMMANDS = path.join(process.cwd(), "..", "Sources/FTDSL/Commands.swift");

/// 要素を1つに定めないので「掴んだ要素の検証」にならない = チェーンにしない
const EXEMPT = new Set(["notExist", "countIs", "screenIs"]);

/// 検証コマンドの見分け: assert を組み立てる共通実装のいずれかを呼ぶもの
const ASSERT_IMPLS = ["textAssert(", "emptyAssert(", "enabledAssert(", "assert: \""];

function readSource() {
  return readFileSync(COMMANDS, "utf8");
}

/// String 版の自由関数のうち、検証系のものの名前
function assertionFreeFunctions(source) {
  const upToFTElement = source.slice(0, source.indexOf("public struct FTElement"));
  const names = new Set();
  const pattern = /^public func ([a-zA-Z]+)\(_ selector: String[\s\S]*?\n\}/gm;
  for (const match of upToFTElement.matchAll(pattern)) {
    const [body, name] = [match[0], match[1]];
    if (ASSERT_IMPLS.some((impl) => body.includes(impl))) names.add(name);
  }
  return names;
}

function chainMethods(source) {
  const body = source.slice(source.indexOf("public struct FTElement"));
  return new Set([...body.matchAll(/^    public func ([a-zA-Z]+)\(/gm)].map((m) => m[1]));
}

test("FTElement: 検証系の自由関数はすべてチェーンにも生えている", () => {
  const source = readSource();
  const free = assertionFreeFunctions(source);
  const chain = chainMethods(source);

  // 検出器そのものが壊れていないこと(0 件なら正規表現が腐っている)
  assert.ok(free.size >= 20, `検証系の自由関数を取りこぼしている: ${free.size} 件`);

  const missing = [...free].filter((name) => !EXEMPT.has(name) && !chain.has(name)).sort();
  assert.deepEqual(
    missing,
    [],
    `FTElement にチェーンが無い検証コマンド: ${missing.join(", ")}\n`
      + "(自由関数だけ足すと exist(...).xxx が書けず、規則性が崩れる)",
  );
});

test("FTElement: 対象外のコマンドはチェーンに生やさない", () => {
  const chain = chainMethods(readSource());
  for (const name of EXEMPT) {
    assert.ok(!chain.has(name), `${name} は要素を1つに定めないのでチェーンにしない`);
  }
});
