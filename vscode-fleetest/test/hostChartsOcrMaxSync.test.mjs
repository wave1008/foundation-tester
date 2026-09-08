// OCR スパークラインの縦軸の下限が、Swift 側の OCR 拡大再読みの段数と一致していることの検証。
//
// occlusion-guard の1ステップは、読めなければ crop を拡大して読み直す(RegionText.upscaleLadder)
// ので最大 upscaleLadder.count 回まで OCR を撃つ。**ズレても両方とも成功する**(描画も判定も
// 通る)ので、目視では気付けない —— 段数を動かしたら目盛りも見直させるために等号で縛る
// (hostChartsFmMaxSync.test.mjs と同じ作法)。
//
// 同期相手:
//   Sources/FTCore/RegionText.swift                       upscaleLadder
//   vscode-fleetest/src/webview/monitor/hostChartScale.js HM_OCR_MAX_RATE
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");

test("OCR グラフの下限が Swift 側の upscaleLadder の段数と一致する", () => {
  const swift = readFileSync(path.join(REPO, "Sources/FTCore/RegionText.swift"), "utf8");
  const ladderMatch = swift.match(/upscaleLadder\s*=\s*\[([^\]]*)\]/);
  assert.ok(ladderMatch, "RegionText.swift から upscaleLadder を抽出できません");
  const steps = ladderMatch[1].split(",").map((s) => s.trim()).filter((s) => s.length > 0).length;

  const charts = readFileSync(path.join(ROOT, "src/webview/monitor/hostChartScale.js"), "utf8");
  const chartsMatch = charts.match(/HM_OCR_MAX_RATE\s*=\s*(\d+)/);
  assert.ok(chartsMatch, "hostChartScale.js から HM_OCR_MAX_RATE を抽出できません");

  assert.equal(Number(chartsMatch[1]), steps,
    "OCR グラフの下限が RegionText.upscaleLadder の段数とズレています");
});

test("OCR の縦軸は HM_OCR_MAX_RATE を下限としたオートスケール", async () => {
  const { hmCountScale, HM_OCR_MAX_RATE } = await import("../src/webview/monitor/hostChartScale.js");
  assert.equal(HM_OCR_MAX_RATE, 3, "この後の期待値はすべて HM_OCR_MAX_RATE=3 前提");
  const scale = (samples) => hmCountScale(samples, HM_OCR_MAX_RATE);

  assert.equal(scale([0, 0, 0]), 3, "小さい窓でも 3 より縮めない");
  assert.equal(scale([1, 2]), 3, "3 未満は 3 のまま");
  assert.equal(scale([1, 3]), 3, "ちょうど 3 は 3");
  assert.equal(scale([1, 9, 2]), 9, "3 を超えたら最大値まで伸ばす(天井で潰さない)");
  assert.equal(scale([]), 3, "空なら下限");
  assert.equal(scale([null, null]), 3, "全欠測なら下限");
});

// FM と OCR は別々の縦軸(片方に合わせると読めなくなる) —— 同じ hmCountScale を通っても
// floor が違えば結果が違うことを確かめる
test("FM と OCR は同じ入力でも下限が違えば結果が違う", async () => {
  const { hmCountScale, HM_FM_MAX_RATE, HM_OCR_MAX_RATE } = await import("../src/webview/monitor/hostChartScale.js");
  assert.notEqual(HM_FM_MAX_RATE, HM_OCR_MAX_RATE, "下限が同じなら別軸にする意味の一部が消える");
  assert.equal(hmCountScale([1, 2], HM_FM_MAX_RATE), HM_FM_MAX_RATE);
  assert.equal(hmCountScale([1, 2], HM_OCR_MAX_RATE), HM_OCR_MAX_RATE);
});
