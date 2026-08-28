// tileFitModel.js(デバイスタブ auto-fit の高さ計算)のユニットテスト。
// DOM 非依存の純ロジックなので、実測値を直接渡して検証する。
//
// 検証の要点は3つ:
//   ① 返した高さで実際に横スクロールが出ない(逆算して合計幅 <= gridWidth)
//   ② 画像が隠れない(返り値は必ず「画像以外の高さ + 画像の高さ」以上)
//   ③ 下限を下回るくらい台数が多いときは、縮めるのではなく横スクロールに任せる

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  computeFitPaneHeight,
  FIT_SLACK_PX,
  MIN_FIT_IMAGE_HEIGHT_PX,
} from "../src/webview/monitor/tileFitModel.js";

/** 返された高さで再レイアウトしたときのタイル合計幅(px)。gridWidth 以下なら収まる。 */
function totalWidthAt(paneHeight, m) {
  const imageHeight = paneHeight - m.paneOverhead;
  const gaps = m.gap * (m.tiles.length - 1);
  return (
    m.tiles.reduce(
      (sum, tile) =>
        sum +
        tile.chromeWidth +
        Math.max(tile.floorWidth || 0, (tile.imageWidth / m.imageHeight) * imageHeight),
      0,
    ) + gaps
  );
}

/** 同一機種 n 台(1台ぶんの実測値 240x519 相当)。 */
function uniform(count, { gridWidth, paneOverhead = 100, imageHeight = 300 } = {}) {
  return {
    paneOverhead,
    imageHeight,
    gridWidth,
    gap: 8,
    tiles: Array.from({ length: count }, () => ({ imageWidth: 138.5, chromeWidth: 18 })),
  };
}

/** その構成で auto-fit がこれ以上縮めない高さ。 */
const floorPaneHeight = (m) => Math.floor(m.paneOverhead + MIN_FIT_IMAGE_HEIGHT_PX);

test("台数が増えるほど収まる高さは低くなる", () => {
  const heights = [2, 3, 4, 6].map((n) => computeFitPaneHeight(uniform(n, { gridWidth: 1200 })));
  for (const height of heights) {
    assert.equal(typeof height, "number");
  }
  for (let i = 1; i < heights.length; i++) {
    assert.ok(heights[i] < heights[i - 1], `${heights[i]} < ${heights[i - 1]}`);
  }
});

test("収まる台数では横スクロールが出ない(合計幅 <= grid 幅)", () => {
  for (const count of [1, 2, 3, 5, 8, 13]) {
    for (const gridWidth of [640, 900, 1200, 1920]) {
      const m = uniform(count, { gridWidth });
      const fitted = computeFitPaneHeight(m);
      assert.equal(typeof fitted, "number");
      if (fitted === floorPaneHeight(m)) {
        continue; // 下限に張り付いた構成は横スクロールに任せる(下の専用テスト)
      }
      const total = totalWidthAt(fitted, m);
      // 1px 残す: 端数の切り上げで横スクロールバーが出るのを防ぐ余白(FIT_SLACK_PX)
      assert.ok(total <= gridWidth - 1, `count=${count} width=${gridWidth}: total=${total}`);
      // 余らせすぎない: 余白は「切り捨て1px ぶんのタイル幅」+ スラック程度に収まる
      assert.ok(gridWidth - total < count * 2 + FIT_SLACK_PX + 1, `count=${count}: 余白 ${gridWidth - total}`);
    }
  }
});

test("下限を下回る台数では縮めずに横スクロールへ倒す", () => {
  // 22 台を 1200px の細いパネルへ。1行に詰めると画像は 60px 前後まで潰れる。
  const m = uniform(22, { gridWidth: 1200 });
  const fitted = computeFitPaneHeight(m);
  assert.equal(fitted, floorPaneHeight(m), "下限で止まる");
  assert.ok(totalWidthAt(fitted, m) > m.gridWidth, "収まらないぶんは横スクロールで見る");
});

test("返す高さでは画像が隠れない(下限より低い高さは返さない)", () => {
  for (const count of [1, 5, 13, 22, 60]) {
    for (const gridWidth of [400, 900, 1971]) {
      const m = uniform(count, { gridWidth });
      const fitted = computeFitPaneHeight(m);
      assert.ok(
        fitted - m.paneOverhead >= MIN_FIT_IMAGE_HEIGHT_PX,
        `count=${count} width=${gridWidth}: 画像高さ ${fitted - m.paneOverhead}`,
      );
    }
  }
});

test("画像以外の高さ(paneOverhead)はそのまま足して返す", () => {
  const a = computeFitPaneHeight(uniform(4, { gridWidth: 1200, paneOverhead: 100 }));
  const b = computeFitPaneHeight(uniform(4, { gridWidth: 1200, paneOverhead: 160 }));
  assert.equal(b - a, 60, "マシン名の段が増えた分だけ高くなる");
});

test("画像以外の子が要求する幅(床)は固定費として引かない", () => {
  const withFloor = uniform(6, { gridWidth: 1200 });
  for (const tile of withFloor.tiles) {
    tile.floorWidth = 90; // マシン名バッジの段が要求する幅
  }
  // 同じ幅を「タイルの固定費」として扱った場合(=床を知らない旧モデル相当)
  const asChrome = uniform(6, { gridWidth: 1200 });
  for (const tile of asChrome.tiles) {
    tile.chromeWidth += 90;
  }
  const fitted = computeFitPaneHeight(withFloor);
  assert.ok(
    fitted > computeFitPaneHeight(asChrome),
    "床は画像が広がるまで幅を食わないので、固定費扱いより高くできる",
  );
  assert.ok(totalWidthAt(fitted, withFloor) <= withFloor.gridWidth, "それでも横スクロールは出ない");
});

test("床のせいで収まらないときも下限で止める(床を無視すると溢れる高さを返す)", () => {
  // マシン名バッジの段が 200px を要求する6台。画像を下限まで縮めてもタイルは 218px 幅の
  // ままなので1行には収まらない —— 床を見ずに画像幅だけで解くと 300px 超の高さを返す。
  const m = uniform(6, { gridWidth: 1200 });
  for (const tile of m.tiles) {
    tile.floorWidth = 200;
  }
  const fitted = computeFitPaneHeight(m);
  assert.equal(fitted, floorPaneHeight(m), "下限で止まる");
  assert.ok(totalWidthAt(fitted, m) > m.gridWidth, "収まらないぶんは横スクロールで見る");
});

test("床より画像が広ければ床は効かない(床の有無で結果が変わらない)", () => {
  const base = uniform(3, { gridWidth: 1200 });
  const withSmallFloor = uniform(3, { gridWidth: 1200 });
  for (const tile of withSmallFloor.tiles) {
    tile.floorWidth = 10; // 画像幅(この構成では 180px 前後)より十分狭い
  }
  assert.equal(computeFitPaneHeight(withSmallFloor), computeFitPaneHeight(base));
});

test("アスペクト比の違うタイルが混在しても合計幅が grid 幅に収まる", () => {
  const m = {
    paneOverhead: 140,
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
  assert.ok(fitted < m.paneOverhead + m.imageHeight, "はみ出しているので縮む");
  assert.ok(totalWidthAt(fitted, m) <= m.gridWidth);
});

test("余っているときは高さを増やす(1台で幅が余る)", () => {
  const m = uniform(1, { gridWidth: 1200 });
  const fitted = computeFitPaneHeight(m);
  assert.ok(fitted > m.paneOverhead + m.imageHeight);
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
  assert.equal(computeFitPaneHeight({ ...base, paneOverhead: NaN }), null, "タイル高さが測れない");
  assert.equal(
    computeFitPaneHeight({ ...base, tiles: [{ imageWidth: 0, chromeWidth: 18 }] }),
    null,
    "レイアウト未確定のタイル",
  );
  // 「画像に割ける幅が無い」は測れないのではなく収まらないだけ = 下限へ倒す
  const narrow = { ...base, gridWidth: 40 };
  assert.equal(computeFitPaneHeight(narrow), floorPaneHeight(narrow));
});
