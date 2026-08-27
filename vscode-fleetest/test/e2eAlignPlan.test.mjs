// Scripts/e2e.sh の `--align` が見るプロファイル集合(planned_profiles)と、実行ループが実際に
// 回す組(run_profile の呼び出し)の一致検証。
//
// 契約: align は「この実行が使うランナー」だけを揃える。集合の導出は planned_profiles に写して
// あるので、SUT やプロファイルを片方だけ足すと **align が別の集合を見に行き、黙って
// 「揃えるものはありません」と言う**(そのプロファイルは開始前の適合チェックで丸ごと落ちる)。
// e2e.sh 自身も実行後に突き合わせて警告するが、そちらは**フルスイートを回さないと出ない**ので、
// ソース走査で秒未満に落とす。
//
// 併せて Scripts/e2e-align-plan.py の判定(どの関係のときに align するか)も実際に走らせて固定する。
// **align してよいのは remoteBehind だけ** —— 向きを取り違えると、こちらが古いときに
// ランナーを引き下げる(docs/remote-runner.md §18.3 規則1)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const E2E_SH = readFileSync(path.join(ROOT, "Scripts/e2e.sh"), "utf8");

/** planned_profiles() の本文から `<PROJECT> <PROFILE>` の組を拾う。 */
function plannedPairs() {
  const begin = E2E_SH.indexOf("planned_profiles() {");
  assert.ok(begin > 0, "e2e.sh に planned_profiles がありません(--align の集合の定義元)");
  const body = E2E_SH.slice(begin, E2E_SH.indexOf("\n}\n", begin));
  return new Set([...body.matchAll(/echo "([A-Za-z0-9-]+) (\$IOS_PROFILE|android)"/g)]
    .map((m) => `${m[1]} ${m[2]}`));
}

/** 実行ループの `run_profile <PROJECT> <PROFILE>` 呼び出しを拾う(関数定義自身は除く)。 */
function ranPairs() {
  const defAt = E2E_SH.indexOf("run_profile() {");
  const body = E2E_SH.slice(E2E_SH.indexOf("\n}\n", defAt));
  return new Set([...body.matchAll(/run_profile ([A-Za-z0-9-]+) "?(\$IOS_PROFILE|android)"?/g)]
    .map((m) => `${m[1]} ${m[2]}`));
}

test("planned_profiles が実行ループの全プロファイルを網羅する", () => {
  const planned = plannedPairs();
  const ran = ranPairs();
  assert.ok(ran.size >= 8, `実行ループから組を抽出できません: ${[...ran]}`);
  assert.deepEqual([...planned].sort(), [...ran].sort(),
    "planned_profiles と run_profile の組が食い違っています(--align が別の集合を見に行きます)");
});

/** e2e-align-plan.py を実際に走らせる(実装の写しを置かない)。 */
function plan(machines, published = true) {
  const out = execFileSync("python3", [path.join(ROOT, "Scripts/e2e-align-plan.py"), "T/p"], {
    input: JSON.stringify({ machines, revisionPublished: published }), encoding: "utf8",
  });
  return out.split("\n").filter(Boolean).map((l) => l.split("|"));
}

test("align するのはランナーが祖先(remoteBehind)のときだけ", () => {
  const base = { reachable: true, revisionCompatible: false, toolchainCompatible: true };
  for (const [relation, action] of [
    ["remoteBehind", "align"],
    ["localBehind", "skip"],   // こちらが古い → 直すのは自分。ランナーを引き下げない
    ["diverged", "skip"],      // ブランチ作業 → 共有ランナーでは解決しない
    [null, "skip"],            // 向き不明 → 触らない
  ]) {
    const rows = plan([{ ...base, machine: "H", revisionRelation: relation }]);
    assert.equal(rows.length, 1, `${relation}: 1行だけ出す`);
    assert.equal(rows[0][0], action, `relation=${relation} で ${action} にならない`);
    if (action === "skip") assert.ok(rows[0][2].length > 0, "触らない理由を必ず出す");
  }
});

test("align で直らないズレは触らず理由を出す", () => {
  const unreachable = plan([{ machine: "H", reachable: false, error: "ssh timeout" }]);
  assert.deepEqual(unreachable.map((r) => r[0]), ["skip"]);
  assert.match(unreachable[0][2], /到達/);

  // toolchain 不一致は rev が合っていても align では直らない(別行で必ず言う)
  const toolchain = plan([{
    machine: "H", reachable: true, revisionCompatible: true, toolchainCompatible: false,
  }]);
  assert.deepEqual(toolchain.map((r) => r[0]), ["skip"]);
  assert.match(toolchain[0][2], /toolchain/);

  // 未 push の rev はランナーが fetch できない = align 案内が誤誘導になる
  const unpublished = plan([{
    machine: "H", reachable: true, revisionCompatible: false, revisionRelation: null,
    toolchainCompatible: true,
  }], false);
  assert.deepEqual(unpublished.map((r) => r[0]), ["skip"]);
  assert.match(unpublished[0][2], /push/);
});

test("版が合っているホストは何も出さない(無駄な align を撃たない)", () => {
  assert.deepEqual(plan([{
    machine: "H", reachable: true, revisionCompatible: true, toolchainCompatible: true,
  }]), []);
});
