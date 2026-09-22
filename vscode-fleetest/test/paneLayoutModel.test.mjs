// セパレーターの可動域(src/webview/monitor/paneLayoutModel.js)。jsdom では offsetHeight が
// 全部 0 で高さを測れないため、算術だけを純粋関数に切り出してここで固める。
// 守るのは1つ: **どこまでドラッグしても run ボード/実行ログビュー/グリッドビューの見出し行は残る**。

import assert from "node:assert/strict";
import test from "node:test";
import { clampHeight, tilePaneLimits, logPaneLimits, runBoardLimits } from "../src/webview/monitor/paneLayoutModel.js";

// 実測の代わりの例: 下2ペインは見出し + 上下パディングで 1 枚 40px
const LOG_CHROME = 40;
const GRID_CHROME = 40;

test("ラインビューを下いっぱいへ引いても下2ペインの見出し行ぶんは残す", () => {
  const { min, max } = tilePaneLimits({ available: 600, bottomChrome: LOG_CHROME + GRID_CHROME, minTile: 120 });
  assert.equal(min, 120);
  assert.equal(max, 520);
  assert.equal(clampHeight(10_000, min, max), 520, "下限まで引いても 600 - 80 で止まる");
  assert.equal(clampHeight(0, min, max), 120);
});

test("領域が足りないときは最小値を返す(max < min でも下回らない)", () => {
  const { min, max } = tilePaneLimits({ available: 100, bottomChrome: 80, minTile: 120 });
  assert.equal(max, 120, "available - bottomChrome が min を下回っても min まで");
  assert.equal(clampHeight(10_000, min, max), 120);
});

test("実行ログビューは自分の見出し行まで縮み、グリッドビューの見出し行は残す", () => {
  const { min, max } = logPaneLimits({ bottomAvailable: 400, logChrome: LOG_CHROME, gridChrome: GRID_CHROME });
  assert.equal(min, 40, "上いっぱいへ引くと見出し行だけになる(消えはしない)");
  assert.equal(max, 360, "下いっぱいへ引いてもグリッドビューの見出し行は残る");
  assert.equal(clampHeight(-50, min, max), 40);
  assert.equal(clampHeight(10_000, min, max), 360);
});

test("下の領域が見出し2枚ぶんしか無ければ実行ログビューは見出し行の高さで固定", () => {
  const { min, max } = logPaneLimits({ bottomAvailable: 80, logChrome: LOG_CHROME, gridChrome: GRID_CHROME });
  assert.equal(min, 40);
  assert.equal(max, 40);
  assert.equal(clampHeight(10_000, min, max), 40);
});

// ---- run ボード(「実行中」と「デバイス」の間のセパレーター) ----
// 実測の代わりの例: run ボードの見出し行は 28px・3ペインの最小は 120 + 40 + 40。
const RUN_BOARD_HEADER = 28;
const PANES_MIN = 120 + LOG_CHROME + GRID_CHROME;

test("run ボードを下いっぱいへ引いても3ペインの最小は残す", () => {
  const { min, max } = runBoardLimits({ available: 600, headerHeight: RUN_BOARD_HEADER, panesMin: PANES_MIN });
  assert.equal(min, 28, "上いっぱいへ引くと見出し行だけになる(消えはしない)");
  assert.equal(max, 400, "下いっぱいへ引いても 600 - 200 で止まる");
  assert.equal(clampHeight(10_000, min, max), 400);
  assert.equal(clampHeight(0, min, max), 28);
});

test("領域が3ペインの最小に満たなければ run ボードは見出し行の高さで固定", () => {
  const { min, max } = runBoardLimits({ available: 150, headerHeight: RUN_BOARD_HEADER, panesMin: PANES_MIN });
  assert.equal(max, 28, "available - panesMin が min を下回っても min まで");
  assert.equal(clampHeight(10_000, min, max), 28);
});
