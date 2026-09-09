// シナリオ別サマリの「平均sec」セルの整形。記録(avgDurationMs)は ms なので、
// 秒へ割る係数と小数桁が崩れても**表は描かれたまま**数字だけが1000倍ズレる。
import assert from "node:assert/strict";
import { test } from "node:test";

import { formatDurationSeconds, formatPercentInteger } from "../src/webview/dashboard/format.js";

test("平均sec は ms を秒へ直して小数1桁で出す", () => {
  assert.equal(formatDurationSeconds(11679), "11.7s");
  assert.equal(formatDurationSeconds(1000), "1.0s");
  assert.equal(formatDurationSeconds(0), "0.0s");
  // 0 桁に丸めると 0.4s と 1.4s が 0s/1s に化けて比較にならない
  assert.equal(formatDurationSeconds(449), "0.4s");
  assert.equal(formatDurationSeconds(1449), "1.4s");
});

test("数値でない平均は '–'(avgDurationMs は対象 0 件で null になる契約)", () => {
  assert.equal(formatDurationSeconds(null), "–");
  assert.equal(formatDurationSeconds(undefined), "–");
});

// 成功率は整数。**丸めで 100% に化けない**ことがこの関数の要点 ——
// 1回でも失敗した窓を「全部成功」と読ませると、赤を見落とす
test("成功率は小数を落とし、100 未満は切り捨てる", () => {
  assert.equal(formatPercentInteger(90), "90%");
  assert.equal(formatPercentInteger(100), "100%");
  assert.equal(formatPercentInteger(99.6), "99%");
  assert.equal(formatPercentInteger(0), "0%");
  assert.equal(formatPercentInteger(66.666), "66%");
  assert.equal(formatPercentInteger(null), "–");
  assert.equal(formatPercentInteger(undefined), "–");
});
