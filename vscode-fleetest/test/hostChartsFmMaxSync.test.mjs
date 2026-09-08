// FM スパークラインの縦軸の上限が、CLI 側の FM 並列枠の既定と一致していることの検証。
//
// 目盛りは**この値を下限とするオートスケール**(超えたら伸びる。下回っても縮まない)。
// 5 は読みやすさのための下限で、物理的な上限ではない ——
// 枠が縛るのは同時実行数であって1秒あたりの回数ではなく、1 tick の回数は概ね 枠 ÷ レイテンシ。
// FM 1回が実測 1.4〜2.1 秒なので門を通る run では結果的に枠数を下回るだけで、
// 門を通らない `doctor --fm-load` は普通に超える(天井で頭打ちになる)。
// それでも枠数は目盛りの妥当な目安なので、**枠数を動かしたら目盛りも見直させる**ために等号で縛る。
// ズレても**両方とも成功する**(描画も run も通る)ので、目視では気付けない。
//
// 同期相手:
//   Sources/FTCore/FMLock.swift                       defaultConcurrency
//   vscode-fleetest/src/webview/monitor/hostChartScale.js HM_FM_MAX_RATE
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

test("FM グラフの上限が Swift 側の FM 並列枠の既定と一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/FMLock.swift"), "utf8");
  const swiftMatch = swift.match(/defaultConcurrency\s*=\s*(\d+)/);
  assert.ok(swiftMatch, "FMLock.swift から defaultConcurrency を抽出できません");

  const charts = readFileSync(path.join(ROOT, "src/webview/monitor/hostChartScale.js"), "utf8");
  const chartsMatch = charts.match(/HM_FM_MAX_RATE\s*=\s*(\d+)/);
  assert.ok(chartsMatch, "hostChartScale.js から HM_FM_MAX_RATE を抽出できません");

  assert.equal(Number(chartsMatch[1]), Number(swiftMatch[1]),
    "FM グラフの上限が FMLock.defaultConcurrency とズレています");
});

// 縦軸の目盛り。**下限を割らない**ことと**超えたら伸びる**ことの両方を見る ——
// 片方だけだと「常に固定」も「純粋なオートスケール」も素通りする。
// floor は呼び出し側が渡す(既定値を持たない) —— FM の下限は HM_FM_MAX_RATE(5)。
test("FM の縦軸は 5 を下限としたオートスケール", async () => {
  const { hmCountScale, HM_FM_MAX_RATE } = await import("../src/webview/monitor/hostChartScale.js");
  assert.equal(HM_FM_MAX_RATE, 5, "この後の期待値はすべて HM_FM_MAX_RATE=5 前提");
  const scale = (samples) => hmCountScale(samples, HM_FM_MAX_RATE);

  assert.equal(scale([0, 0, 0]), 5, "小さい窓でも 5 より縮めない");
  assert.equal(scale([1, 2, 3]), 5, "5 未満は 5 のまま(行同士を比べられる)");
  assert.equal(scale([1, 5, 2]), 5, "ちょうど 5 は 5");
  assert.equal(scale([1, 8, 2]), 8, "5 を超えたら最大値まで伸ばす(天井で潰さない)");
  assert.equal(scale([]), 5, "空なら下限");
  assert.equal(scale([null, null]), 5, "全欠測なら下限");
  assert.equal(scale([null, 9, null]), 9, "欠測は無視して最大値を採る");
  // **ガードを外すと Math.max(..., undefined) が NaN になり、線が1本も描かれなくなる**
  // (null は 0 に強制されるので素通りする —— undefined でしか捕まらない)
  assert.equal(scale([undefined, 7]), 7, "undefined でも NaN にしない");
});

// 行ごとに取ると「2回の機械」と「8回の機械」が同じ高さに描かれ、並べて比べる意味が消える
test("FM の縦軸は全行のサンプルから1つだけ決まる", async () => {
  const { hmSharedCountScale, HM_FM_MAX_RATE } = await import("../src/webview/monitor/hostChartScale.js");
  const scale = (perRowSamples) => hmSharedCountScale(perRowSamples, HM_FM_MAX_RATE);

  assert.equal(scale([[1, 2], [8], [0]]), 8, "一番大きい行に全体を合わせる");
  assert.equal(scale([[1], [2], [3]]), 5, "全行が小さければ下限のまま");
  assert.equal(scale([[], []]), 5, "空でも下限");
  assert.equal(scale([[null, 9], [1]]), 9, "欠測を跨いでも最大を採る");
  assert.equal(scale([]), 5, "行が1つも無ければ下限");
});

// **floor に既定値を置かない**ことの検証。渡し忘れると Math.max(undefined, ...) が NaN になり
// 「片方の下限へ静かに落ちる」のではなく、はっきり壊れる(気付ける形にするための設計)
test("floor を渡さないと NaN になる(既定値を持たない)", async () => {
  const { hmCountScale } = await import("../src/webview/monitor/hostChartScale.js");
  assert.ok(Number.isNaN(hmCountScale([1, 2])), "floor 省略は NaN(黙って FM/OCR どちらかへ倒れない)");
});
