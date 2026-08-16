// SUT の UI 契約ドリフト検出。
// 契約(CLAUDE.md): 要素の testTag/`#id`/ラベルの唯一の正は E2EAppCMP/docs/ui-contract.md。
// 各 SUT の <SUT>/docs/ui-contract.md には型語彙と OS/フレームワーク固有の罠だけを置く。
// SUT 側の契約が母体に無い `#id` を語り出すと、4つの SUT が同じ画面契約を共有しているという前提が
// 静かに崩れ、シナリオがどの SUT で通るのか分からなくなる。
//
// 検査は「SUT 側に出る #id は母体にも在る」の一方向。母体にあって SUT 側に出ない id は正常
// (SUT 側は差分だけを書く)。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const MASTER = "E2EAppCMP/docs/ui-contract.md";
const SUT_CONTRACTS = [
  "E2EAppIOS/docs/ui-contract.md",
  "E2EAppAndroid/docs/ui-contract.md",
  "E2EAppFlutter/docs/ui-contract.md",
  "E2EAppRN/docs/ui-contract.md",
];

const ID_PATTERN = /#[a-z][a-z0-9_]*/g;

/**
 * 母体が宣言する id 集合。`#row_01` … `#row_40` のような連番の範囲記法を展開する
 * (展開しないと `#row_03` を参照する SUT 契約が誤検出になる)。
 */
function declaredIDs(source) {
  const ids = new Set(source.match(ID_PATTERN) ?? []);
  const rangePattern = /#([a-z][a-z0-9_]*?)_(\d+)`?\s*…\s*`?#\1_(\d+)/g;
  for (const [, prefix, from, to] of source.matchAll(rangePattern)) {
    const width = from.length;
    for (let n = Number(from); n <= Number(to); n++) {
      ids.add(`#${prefix}_${String(n).padStart(width, "0")}`);
    }
  }
  return ids;
}

test("母体 ui-contract から id を抽出でき、連番の範囲記法が展開される", () => {
  const master = declaredIDs(readFileSync(path.join(ROOT, MASTER), "utf8"));
  assert.ok(master.size > 0, `${MASTER} から #id を抽出できません`);
  // 範囲記法の展開が効いていること(効かないと下のテストが誤検出になる)
  assert.ok(
    master.has("#row_01") && master.has("#row_40"),
    `${MASTER} の連番範囲(#row_01 … #row_40)を展開できていません`,
  );
});

for (const contract of SUT_CONTRACTS) {
  test(`${contract} の #id はすべて母体 ui-contract に存在する`, () => {
    const master = declaredIDs(readFileSync(path.join(ROOT, MASTER), "utf8"));
    const source = readFileSync(path.join(ROOT, contract), "utf8");
    const used = new Set(source.match(ID_PATTERN) ?? []);

    const unknown = [...used].filter((id) => !master.has(id)).sort();
    assert.deepEqual(
      unknown,
      [],
      `${contract} が母体に無い #id を参照しています: ${unknown.join(", ")}\n` +
        `要素の testTag/#id/ラベルの唯一の正は ${MASTER} です。` +
        "id を足すならまず母体に足し、SUT 側には型語彙と固有の罠だけを書くこと",
    );
  });
}
