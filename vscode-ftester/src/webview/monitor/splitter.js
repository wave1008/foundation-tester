// splitter.js
// デバイスタブの上下ペイン(タイル/出力ログ)を分けるスプリッターのドラッグ操作と、
// タイルペイン高さの計算・永続化(setState/getState)を担う。
// tilePaneHeight は再代入される状態のため、書き込み箇所(applyTilePaneHeight)も含めて
// このモジュールに置く。他モジュール(tabs.js の switchTab)からは読み取り専用で参照する。

import { vscode, persistedState } from './vscodeApi.js';
import { toolbar, banner, devicesPanel, tilePane, splitter } from './domRefs.js';
import { relayoutTiles } from './deviceTiles.js';

// ---- 上下ペインのスプリッター ---------------------------------------------
// タイルペイン(上)の高さを JS 側の状態として保持し、setState/getState にも保存して
// パネル再表示時に復元する。出力ペイン(下)は flex の残りスペースを自動的に占有するので、
// 高さを個別に管理する必要はない。

const MIN_PANE_HEIGHT = 120;
export let tilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : Math.round(window.innerHeight * 0.45);

// タイルペイン+出力ペインに配分できる合計の高さ(ツールバー・バナー・スプリッター分を除く)。
// document.body.clientHeight を基準にするとタブバー分の高さがずれるため、「デバイス」タブの
// パネル(既存要素一式を包むコンテナ)自身の clientHeight を基準にする。
function availableSplitHeight() {
  const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
  return devicesPanel.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
}

// 上下それぞれ最小 MIN_PANE_HEIGHT を確保するようにクランプする。
function clampTilePaneHeight(height) {
  const available = availableSplitHeight();
  const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
  return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
}

export function applyTilePaneHeight(height) {
  // 「デバイス」タブが非表示(display:none)の間は devicesPanel.clientHeight が 0 になり、
  // clampTilePaneHeight が誤って最小値 120px に丸めてしまう。何もせず抜け、タブが
  // 「デバイス」に戻った直後(switchTab)に呼び直して再クランプする。
  if (devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null) {
    return;
  }
  tilePaneHeight = clampTilePaneHeight(height);
  tilePane.style.height = tilePaneHeight + 'px';
  relayoutTiles();
}

function persistTilePaneHeight() {
  vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight }));
}

applyTilePaneHeight(tilePaneHeight);
// ウィンドウリサイズ/バナー表示切替でも上下の最小高さを維持する。
window.addEventListener('resize', () => applyTilePaneHeight(tilePaneHeight));

let splitterPointerId = null;
let splitterStartY = 0;
let splitterStartHeight = 0;

splitter.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) {
    return;
  }
  splitterPointerId = event.pointerId;
  splitterStartY = event.clientY;
  splitterStartHeight = tilePaneHeight;
  splitter.setPointerCapture(event.pointerId);
  splitter.classList.add('dragging');
  event.preventDefault();
});
splitter.addEventListener('pointermove', (event) => {
  if (splitterPointerId !== event.pointerId) {
    return;
  }
  applyTilePaneHeight(splitterStartHeight + (event.clientY - splitterStartY));
});
const endSplitterDrag = (event) => {
  if (splitterPointerId !== event.pointerId) {
    return;
  }
  splitterPointerId = null;
  splitter.classList.remove('dragging');
  splitter.releasePointerCapture(event.pointerId);
  persistTilePaneHeight();
};
splitter.addEventListener('pointerup', endSplitterDrag);
splitter.addEventListener('pointercancel', endSplitterDrag);
