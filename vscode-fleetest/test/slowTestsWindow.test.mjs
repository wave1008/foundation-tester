// ダッシュボードの見出しが名乗る窓("直近N回")が、CLI 側の集計窓と一致していることの検証。
//
// 「遅いテスト」「シナリオ別サマリ」「不安定なシナリオ」は、どれも直近 N run だけで
// 計算している(順に avg/p90/runs/悪化率/最も遅い scene、runs/成功率/平均/中央値、
// 混在判定と遷移スコア)。
// 見出しの N がズレても**両方とも成功する**(描画も集計も通る)ので、目視では気付けない ——
// 読み手は全履歴の集計だと思って、直ったシナリオや直近の悪化を読み違える。
//
// 同期相手:
//   Sources/FTCore/RunResultsQuery.swift             recentScenarioRunsWindow
//   vscode-fleetest/src/i18n/strings/exploreHeal.ts  headingSlow / headingSummary /
//                                                    headingFlaky (ja/en)
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

function swiftWindow() {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/RunResultsQuery.swift"), "utf8");
  const match = swift.match(/recentScenarioRunsWindow\s*=\s*(\d+)/);
  assert.ok(match, "RunResultsQuery.swift から recentScenarioRunsWindow を抽出できません");
  return Number(match[1]);
}

function headingPair(key) {
  const dict = readFileSync(path.join(ROOT, "src/i18n/strings/exploreHeal.ts"), "utf8");
  const block = dict.match(new RegExp(`"exploreHeal\\.dashboard\\.${key}":\\s*\\{([^}]*)\\}`));
  assert.ok(block, `exploreHeal.ts から ${key} を抽出できません`);
  const ja = block[1].match(/ja:\s*"([^"]*)"/);
  const en = block[1].match(/en:\s*"([^"]*)"/);
  assert.ok(ja && en, `${key} の ja/en を抽出できません`);
  return { ja: ja[1], en: en[1] };
}

test("遅いテストの見出しの「直近N回」が Swift 側の集計窓と一致する", () => {
  const window = swiftWindow();
  const { ja, en } = headingPair("headingSlow");
  assert.equal(ja, `遅いテスト(直近${window}回)`, "ja の見出しが集計窓とズレています");
  assert.equal(en, `Slow Tests (last ${window} runs)`, "en の見出しが集計窓とズレています");
});

test("シナリオ別サマリの見出しの「直近N回」が Swift 側の集計窓と一致する", () => {
  const window = swiftWindow();
  const { ja, en } = headingPair("headingSummary");
  assert.equal(ja, `シナリオ別サマリ(直近${window}回)`, "ja の見出しが集計窓とズレています");
  assert.equal(en, `Scenario Summary (last ${window} runs)`, "en の見出しが集計窓とズレています");
});

test("不安定なシナリオの見出しの「直近N回」が Swift 側の集計窓と一致する", () => {
  const window = swiftWindow();
  const { ja, en } = headingPair("headingFlaky");
  assert.equal(ja, `不安定なシナリオ(直近${window}回)`, "ja の見出しが集計窓とズレています");
  assert.equal(en, `Flaky Scenarios (last ${window} runs)`, "en の見出しが集計窓とズレています");
});
