// TOOL_ROOT(ツール本体のクローン)解決規則の4実装ドリフト検出。
// 実装は Scripts/preflight.sh / Scripts/update.sh / Scripts/update-check.sh /
// src/toolRootResolve.ts の4箇所にあり、CLAUDE.md が「片方だけ変えない」と定めている。
// 規則そのもの(clone 構成 = カレント / 外部構成 = Package.swift の .package(path:) →
// 無ければ既定の隣 ../foundation-tester / クローン判別は Sources/FTScenarioRunner の有無)を
// 構成する 3 つの語が全実装に出ることを見る。
//
// 意図的に浅い検査にしている: 4実装は言語も文脈も違うので、規則の等価性を機械的に証明することは
// できない。判別マーカーや既定の隣を1箇所で変えたときに落ちれば、目的(片側だけの変更の検出)は足りる。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");

// 解決規則を構成する語。実装ごとに綴りが違う(shell はパスのリテラル、TS は path.join の分割、
// TS の Package.swift 抽出は正規表現なのでメタ文字がエスケープされる)ため、substring ではなく
// 正規表現で見る。
const RULE_TOKENS = {
  // 末尾を固定しないと改名(foundation-tester-x など)が接頭辞一致で素通りする。
  "クローン判別マーカー": /Sources.{0,20}FTScenarioRunner(?![\w-])/s,
  "既定の隣": /\.\.["'/,\s]*foundation-tester(?![\w-])/,
  "Package.swift の宣言": /\\?\.package\\?\(path:/,
};

const IMPLEMENTATIONS = [
  "Scripts/preflight.sh",
  "Scripts/update.sh",
  "Scripts/update-check.sh",
  "vscode-fleetest/src/toolRootResolve.ts",
];

for (const impl of IMPLEMENTATIONS) {
  test(`TOOL_ROOT 解決規則: ${impl} が規則の3語を持つ`, () => {
    const source = readFileSync(path.join(ROOT, impl), "utf8");
    for (const [label, token] of Object.entries(RULE_TOKENS)) {
      assert.ok(
        token.test(source),
        `${impl} に「${label}」(${token})がありません。TOOL_ROOT の解決規則は ` +
          `${IMPLEMENTATIONS.join(" / ")} の4箇所にあり、片方だけ変えると受け手の導入・更新が壊れます`,
      );
    }
  });
}

test("TOOL_ROOT 解決規則: update.sh は install.sh と同じ規則である旨を明示している", () => {
  // update.sh は自前で解決するが、install.sh 側の規則に追従する契約になっている。
  // ポインタが消えると次に触るエージェントが同期相手を見失う。
  const source = readFileSync(path.join(ROOT, "Scripts/update.sh"), "utf8");
  assert.ok(
    /install\.sh と同じ規則/.test(source),
    "Scripts/update.sh から install.sh との同期を示すコメントが消えています",
  );
});
