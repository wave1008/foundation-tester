// tilePaneHeight は再代入される状態。書き込みは applyTilePaneHeight のみ(このモジュール内)。
// tabs.js の switchTab からは読み取り専用で参照する。

import { vscode, persistedState } from './vscodeApi.js';
import { toolbar, banner, devicesPanel, tilePane, splitter } from './domRefs.js';
import { relayoutTiles } from './deviceTiles.js';

// setState/getStateにも保存し、パネル再表示時に復元する。出力ペインはflexの残りスペースを
// 自動占有するため個別管理は不要。

const MIN_PANE_HEIGHT = 120;
export let tilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : Math.round(window.innerHeight * 0.45);

// document.body.clientHeight だとタブバー分ずれるため、「デバイス」タブパネル自身の
// clientHeight を基準にする。
function availableSplitHeight() {
  const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
  return devicesPanel.clientHeight - toolbar.offsetHeight - bannerHeight - splitter.offsetHeight;
}

function clampTilePaneHeight(height) {
  const available = availableSplitHeight();
  const maxHeight = Math.max(MIN_PANE_HEIGHT, available - MIN_PANE_HEIGHT);
  return Math.min(Math.max(height, MIN_PANE_HEIGHT), maxHeight);
}

export function applyTilePaneHeight(height) {
  // 「デバイス」タブ非表示(display:none)の間はdevicesPanel.clientHeightが0になり、誤って
  // 最小値にクランプしてしまうため何もせず抜ける(タブ復帰時にswitchTabが呼び直す)。
  if (devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null) {
    return;
  }
  tilePaneHeight = clampTilePaneHeight(height);
  tilePane.style.height = tilePaneHeight + 'px';
  relayoutTiles();
}

function persistTilePaneHeight() {
  // getState はパネルを閉じると失われるため、同一セッション内の即時復元用の setState に加えて
  // host(workspaceState)へも保存する(パネル再作成後は "tilePaneHeight" メッセージで復元される。
  // 契約: monitorModel.ts の setTilePaneHeight / tilePaneHeight)。
  vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight }));
  vscode.postMessage({ type: 'setTilePaneHeight', value: tilePaneHeight });
}

// host からの復元値(sendInitialState)を反映する。「デバイス」タブ非表示中は applyTilePaneHeight が
// no-op のため、モジュール変数を直接更新して次の switchTab で反映されるようにする(tilePaneHeight は
// live binding で tabs.js が参照する)。
export function setTilePaneHeight(height) {
  if (typeof height !== 'number' || !(height > 0)) {
    return;
  }
  tilePaneHeight = height;
  applyTilePaneHeight(height);
}

applyTilePaneHeight(tilePaneHeight);
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
