// previewGridModel.js(拡大表示の段組み)のユニットテスト。
// DOM 非依存の純ロジックなので、実測値を直接渡して検証する。
//
// 要件(ユーザー 2026-08-24): 選択した台の**絵の面積が最大になる**ように並べる。
// 2台なら左右、台数が増えて横に詰めると絵が小さくなるところで2段以上へ折り返す。
// 検証の要点は「返した段組みが、他のどの段組みよりも絵を大きくできること」(全探索と照合)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { computePreviewGrid } from "../src/webview/monitor/previewGridModel.js";

// 縦持ちスマホ(390x844)相当の縦横比。実測 --tile-aspect と同じ 幅/高さ。
const PORTRAIT = 390 / 844;
const LANDSCAPE = 844 / 390;

/** その段組みで置ける絵の高さ(px)。負なら1台も置けない。 */
function imageHeightAt(columns, m) {
  const rows = Math.ceil(m.count / columns);
  const cellWidth = (m.paneWidth - m.gap * (columns - 1)) / columns;
  const cellHeight = (m.paneHeight - m.gap * (rows - 1)) / rows - m.chromeHeight;
  return Math.min(cellHeight, cellWidth / m.aspect);
}

function pane(count, { paneWidth = 1200, paneHeight = 400, aspect = PORTRAIT } = {}) {
  return { paneWidth, paneHeight, count, aspect, gap: 10, chromeHeight: 24 };
}

/** 全探索の最大と一致すること(0.5px の同点幅は許容) */
function assertMaximal(m) {
  const got = computePreviewGrid(m);
  const best = Math.max(...Array.from({ length: m.count }, (_, i) => imageHeightAt(i + 1, m)));
  assert.ok(
    imageHeightAt(got.columns, m) > best - 0.5,
    `columns=${got.columns} は最大 ${best.toFixed(1)}px に対して ${imageHeightAt(got.columns, m).toFixed(1)}px`,
  );
  assert.equal(got.rows, Math.ceil(m.count / got.columns), "rows は columns から決まること");
}

test("1台は1列1段", () => {
  assert.deepEqual(computePreviewGrid(pane(1)), { columns: 1, rows: 1 });
});

test("2台は左右に並べる(横長のペイン)", () => {
  assert.deepEqual(computePreviewGrid(pane(2)), { columns: 2, rows: 1 });
});

test("横に詰めると小さくなる台数では段を増やす", () => {
  // 縦に余裕のあるペイン(1200x900)に縦持ち6台。横一列だと1台の幅が 191px まで縮み、
  // 絵の高さも幅で頭打ちになる —— 3列2段にすると幅が倍になり絵も大きくなる。
  const m = pane(6, { paneHeight: 900 });
  const got = computePreviewGrid(m);
  assert.ok(got.rows >= 2, `6台は2段以上になること(得られた段組み: ${got.columns}x${got.rows})`);
  assert.ok(
    imageHeightAt(got.columns, m) > imageHeightAt(6, m),
    "横一列より大きく表示できること",
  );
});

// 「台数を増やすと上下が余ってくる → ある台数から2段」の要件そのもの。
test("台数を増やしていくと、どこかで段が増える(絵が縮み続けない)", () => {
  const shape = { paneWidth: 1200, paneHeight: 900 };
  const rowsByCount = [];
  for (let count = 1; count <= 8; count++) {
    rowsByCount.push(computePreviewGrid(pane(count, shape)).rows);
  }
  assert.deepEqual(rowsByCount.slice(0, 3), [1, 1, 1], "少ない台数は横一列のまま");
  assert.ok(rowsByCount.some((rows) => rows >= 2), `8台までに2段へ折り返すこと: ${rowsByCount}`);
  // 段数は台数に対して単調(増えた台数で段が減る=絵が縮む方向へ戻らない)
  for (let i = 1; i < rowsByCount.length; i++) {
    assert.ok(rowsByCount[i] >= rowsByCount[i - 1], `段数が減っている: ${rowsByCount}`);
  }
});

test("どの台数でも全探索の最大と一致する(1〜12台)", () => {
  for (let count = 1; count <= 12; count++) {
    assertMaximal(pane(count));
  }
});

test("ペインの形が変われば段組みも変わる(縦長・横長・正方形)", () => {
  for (const shape of [
    { paneWidth: 1600, paneHeight: 300 },
    { paneWidth: 600, paneHeight: 900 },
    { paneWidth: 800, paneHeight: 800 },
  ]) {
    for (let count = 1; count <= 9; count++) {
      assertMaximal(pane(count, shape));
    }
  }
});

test("横持ち(タブレット・回転)でも最大に並べる", () => {
  for (let count = 1; count <= 9; count++) {
    assertMaximal(pane(count, { aspect: LANDSCAPE }));
  }
});

test("縦長のペインでは2台でも上下に積む(面積が最大になる方を採る)", () => {
  const m = pane(2, { paneWidth: 400, paneHeight: 1200 });
  const got = computePreviewGrid(m);
  assert.deepEqual(got, { columns: 1, rows: 2 });
  assert.ok(imageHeightAt(1, m) > imageHeightAt(2, m));
});

test("同点なら段数の少ない方 → 列数の少ない方(端だけ空く歪な形にしない)", () => {
  // 1200x900 に縦持ち6台: 3列2段・4列2段・5列2段はどれも絵の高さが 450px で同点
  // (段の高さで頭打ち)。一番詰まった 3列2段を採ること。
  const six = { paneWidth: 1200, paneHeight: 900, count: 6, aspect: PORTRAIT, gap: 0, chromeHeight: 0 };
  assert.equal(imageHeightAt(3, six).toFixed(1), imageHeightAt(5, six).toFixed(1));
  assert.deepEqual(computePreviewGrid(six), { columns: 3, rows: 2 });
});

test("同点なら段数の少ない方(=左右に広げる)を採る", () => {
  // 4台がちょうど 4x1 でも 2x2 でも同じ大きさになる形を作る:
  // 幅を絞って 4x1 の絵が幅で決まり、2x2 は高さで決まるように調整した実測相当値
  const m = { paneWidth: 1000, paneHeight: 1000, count: 4, aspect: 1, gap: 0, chromeHeight: 0 };
  // 4x1: min(1000/4, 1000)=250 / 2x2: min(500,500)=500 → 同点ではないので 2x2 が勝つ
  assert.deepEqual(computePreviewGrid(m), { columns: 2, rows: 2 });
  // 正方形の絵・正方形のペインで2台なら 2x1 と 1x2 は同点 → 2x1(左右)
  const two = { paneWidth: 1000, paneHeight: 1000, count: 2, aspect: 1, gap: 0, chromeHeight: 0 };
  assert.deepEqual(computePreviewGrid(two), { columns: 2, rows: 1 });
});

test("測れない間(タブ非表示・初回描画前)は従来どおり横一列", () => {
  assert.deepEqual(computePreviewGrid(pane(3, { paneWidth: 0, paneHeight: 0 })), { columns: 3, rows: 1 });
  assert.deepEqual(computePreviewGrid({ ...pane(3), aspect: 0 }), { columns: 3, rows: 1 });
});

test("0台でも壊れない", () => {
  assert.deepEqual(computePreviewGrid(pane(0)), { columns: 1, rows: 1 });
});
