// tileFitModel.js(デバイスタブ auto-fit の高さ計算)のユニットテスト。
// DOM 非依存の純ロジックなので、実測値を直接渡して検証する。
//
// 検証の要点は「収まる高さを返す」だけでなく「返した高さで実際に横スクロールが出ない」こと。
// 逆算(returned height → 各タイル幅 → 合計)して gridWidth 以下であることを確かめる。

import assert from "node:assert/strict";
import { test } from "node:test";
import { computeFitPaneHeight, FIT_SLACK_PX } from "../src/webview/monitor/tileFitModel.js";

/** 返された高さで再レイアウトしたときのタイル合計幅(px)。gridWidth 以下なら収まる。 */
function totalWidthAt(paneHeight, m) {
  const scale = (m.imageHeight + (paneHeight - m.paneHeight)) / m.imageHeight;
  const gaps = m.gap * (m.tiles.length - 1);
  return m.tiles.reduce((sum, tile) => sum + tile.imageWidth * scale + tile.chromeWidth, 0) + gaps;
}

/** 同一機種 n 台(1台ぶんの実測値 240x519 相当)。 */
function uniform(count, { gridWidth, paneHeight = 400, imageHeight = 300 } = {}) {
  return {
    paneHeight,
    imageHeight,
    gridWidth,
    gap: 8,
    tiles: Array.from({ length: count }, () => ({ imageWidth: 138.5, chromeWidth: 18 })),
  };
}

test("台数が増えるほど収まる高さは低くなる", () => {
  const heights = [2, 3, 4, 6].map((n) => computeFitPaneHeight(uniform(n, { gridWidth: 1200 })));
  for (const height of heights) {
    assert.equal(typeof height, "number");
  }
  for (let i = 1; i < heights.length; i++) {
    assert.ok(heights[i] < heights[i - 1], `${heights[i]} < ${heights[i - 1]}`);
  }
});

test("返した高さでは横スクロールが出ない(合計幅 <= grid 幅)", () => {
  for (const count of [1, 2, 3, 5, 8, 13]) {
    for (const gridWidth of [640, 900, 1200, 1920]) {
      const m = uniform(count, { gridWidth });
      const fitted = computeFitPaneHeight(m);
      assert.equal(typeof fitted, "number");
      const total = totalWidthAt(fitted, m);
      assert.ok(total <= gridWidth, `count=${count} width=${gridWidth}: total=${total}`);
      // 余らせすぎない: 余白は「切り捨て1px ぶんのタイル幅」+ スラック程度に収まる
      assert.ok(gridWidth - total < count * 2 + FIT_SLACK_PX + 1, `count=${count}: 余白 ${gridWidth - total}`);
    }
  }
});

test("アスペクト比の違うタイルが混在しても合計幅が grid 幅に収まる", () => {
  const m = {
    paneHeight: 500,
    imageHeight: 360,
    gridWidth: 1000,
    gap: 8,
    // 縦持ち(0.46)・横持ち(1.77)・タブレット(0.75)の混在。選択中タイルも内訳は 18px。
    tiles: [
      { imageWidth: 166, chromeWidth: 18 },
      { imageWidth: 637, chromeWidth: 18 },
      { imageWidth: 270, chromeWidth: 18 },
    ],
  };
  const fitted = computeFitPaneHeight(m);
  assert.ok(fitted < m.paneHeight, "はみ出しているので縮む");
  assert.ok(totalWidthAt(fitted, m) <= m.gridWidth);
});

test("余っているときは高さを増やす(1台で幅が余る)", () => {
  const m = uniform(1, { gridWidth: 1200 });
  const fitted = computeFitPaneHeight(m);
  assert.ok(fitted > m.paneHeight);
  assert.ok(totalWidthAt(fitted, m) <= m.gridWidth);
});

test("gap も台数ぶん差し引く(gap が大きいほど低くなる)", () => {
  const base = uniform(5, { gridWidth: 1200 });
  const wideGap = { ...base, gap: 40 };
  assert.ok(computeFitPaneHeight(wideGap) < computeFitPaneHeight(base));
  assert.ok(totalWidthAt(computeFitPaneHeight(wideGap), wideGap) <= wideGap.gridWidth);
});

test("測れないときは null(高さを変えない)", () => {
  const base = uniform(3, { gridWidth: 1200 });
  assert.equal(computeFitPaneHeight(null), null);
  assert.equal(computeFitPaneHeight({ ...base, tiles: [] }), null, "タイル未生成");
  assert.equal(computeFitPaneHeight({ ...base, imageHeight: NaN }), null, "--tile-image-h 未設定");
  assert.equal(computeFitPaneHeight({ ...base, gridWidth: 0 }), null, "タブ非表示で幅0");
  assert.equal(computeFitPaneHeight({ ...base, paneHeight: 0 }), null);
  assert.equal(
    computeFitPaneHeight({ ...base, tiles: [{ imageWidth: 0, chromeWidth: 18 }] }),
    null,
    "レイアウト未確定のタイル",
  );
  assert.equal(
    computeFitPaneHeight({ ...base, gridWidth: 40 }),
    null,
    "chrome と gap だけで幅を使い切る(画像に割ける幅が無い)",
  );
});
