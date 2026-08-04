// 検証コマンドの「3つの書き方」の同期検査(2026-08-04)。
// 契約(Sources/FTDSL/Commands.swift): 検証の対象は**直前に掴んだ要素**で、次の3つは同義。
//
//     select("#x").textIs("OK")            // FTElement のメソッド(判定の実体はここ1か所)
//     select("#x"); lastElement.textIs("OK")
//     select("#x"); textIs("OK")           // トップレベルの自由関数(委譲するだけ)
//
// 片方だけ足すと「その検証はどの書き方でも使えるのか」が覚えられず、書いてみるまで分からない
// (`textIs("#x", "OK")` = セレクタを取る形は置かない)。
//
// 逆方向(自由関数にあってチェーンに無い)も見る: 委譲先が無ければそもそも成立しない。
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const COMMANDS = path.join(process.cwd(), "..", "Sources/FTDSL/Commands.swift");

function readSource() {
  return readFileSync(COMMANDS, "utf8");
}

/// FTElement のメソッド名(判定の実体)。**構造体の終端(行頭 })で切る** —— 切らないと
/// 後続の型のメソッド(FTBranch.ifElse 等)まで拾う
function chainMethods(source) {
  const start = source.indexOf("public struct FTElement");
  const rest = source.slice(start);
  const body = rest.slice(0, rest.indexOf("\n}"));
  return new Set([...body.matchAll(/^    public func ([a-zA-Z]+)\(/gm)].map((m) => m[1]));
}

/// トップレベルの自由関数のうち、`lastElement.<同名>(` へ委譲しているもの
function delegatingFreeFunctions(source) {
  const found = new Map();
  const pattern = /^public func ([a-zA-Z]+)\((?![_\s]*selector)[\s\S]*?\n\}/gm;
  for (const match of source.matchAll(pattern)) {
    const [body, name] = [match[0], match[1]];
    if (body.includes(`lastElement.${name}(`)) found.set(name, body);
  }
  return found;
}

test("検証コマンド: FTElement のメソッドと暗黙 lastElement の自由関数が1対1", () => {
  const source = readSource();
  const chain = chainMethods(source);
  const free = delegatingFreeFunctions(source);

  // 検出器そのものが壊れていないこと(0 件なら正規表現が腐っている)
  assert.ok(chain.size >= 30, `FTElement のメソッドを取りこぼしている: ${chain.size} 件`);
  assert.ok(free.size >= 30, `委譲する自由関数を取りこぼしている: ${free.size} 件`);

  const missingFree = [...chain].filter((name) => !free.has(name)).sort();
  assert.deepEqual(
    missingFree,
    [],
    `暗黙 lastElement の自由関数が無い検証: ${missingFree.join(", ")}\n`
      + "(3つの書き方が同義でなくなる。select(…).x(…) だけ書けて x(…) が書けない状態)",
  );

  const missingChain = [...free.keys()].filter((name) => !chain.has(name)).sort();
  assert.deepEqual(missingChain, [], `委譲先の FTElement メソッドが無い: ${missingChain.join(", ")}`);
});

test("検証コマンド: セレクタを取る旧形が復活していない", () => {
  const source = readSource();
  const revived = [...chainMethods(readSource())].filter((name) =>
    new RegExp(`^public func ${name}\\(_ selector: (String|Sel)`, "m").test(source),
  ).sort();
  assert.deepEqual(
    revived,
    [],
    `セレクタを取る検証が復活している: ${revived.join(", ")}\n`
      + "(対象は直前に掴んだ要素に固定。select(selector).x(expected) と書く)",
  );
});
