// desiredTilePaneHeight=ユーザー意図(ドラッグ・host復元のみで更新、永続化対象)、
// tilePaneHeight=表示用クランプ済み値。分離しないと、パネル表示切替中の一時的に小さい
// レイアウトで resize が走った際にユーザー意図まで最小値へ潰される(実害: エディタ開閉で
// セパレーターが最小位置にリセット)。tabs.js からは reapplyTilePaneHeight を呼ぶ。

import { vscode, persistedState } from './vscodeApi.js';
import { toolbar, banner, devicesPanel, tilePane, splitter } from './domRefs.js';
import { relayoutTiles } from './deviceTiles.js';

// setState/getStateにも保存し、パネル再表示時に復元する。出力ペインはflexの残りスペースを
// 自動占有するため個別管理は不要。

const MIN_PANE_HEIGHT = 120;

// 保存値がない初期表示はスプリット領域の上下中央(50%)。「デバイス」タブ非表示等で
// 領域が測れないときのみ window.innerHeight で代替する。
function defaultTilePaneHeight() {
  const available = availableSplitHeight();
  return Math.round((available > 0 ? available : window.innerHeight) / 2);
}

let desiredTilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : defaultTilePaneHeight();
let tilePaneHeight = desiredTilePaneHeight;

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

// 「デバイス」タブ非表示(display:none)の間はdevicesPanel.clientHeightが0になり、誤って
// 最小値にクランプしてしまうため何もせず抜ける(タブ復帰時にswitchTabが呼び直す)。
function splitAreaHidden() {
  return devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null;
}

function renderTilePaneHeight() {
  tilePaneHeight = clampTilePaneHeight(desiredTilePaneHeight);
  tilePane.style.height = tilePaneHeight + 'px';
  relayoutTiles();
}

// 明示操作(ドラッグ)用: desired を更新してから描画する。
export function applyTilePaneHeight(height) {
  if (splitAreaHidden()) {
    return;
  }
  desiredTilePaneHeight = clampTilePaneHeight(height);
  renderTilePaneHeight();
}

// resize・タブ復帰用: desired は変えず現レイアウトへ再クランプするだけ。一時的に狭い
// レイアウトでもユーザー意図を失わず、広がれば desired まで戻る。
export function reapplyTilePaneHeight() {
  if (splitAreaHidden()) {
    return;
  }
  renderTilePaneHeight();
}

function persistTilePaneHeight() {
  // getState はパネルを閉じると失われるため、同一セッション内の即時復元用の setState に加えて
  // host(workspaceState)へも保存する(パネル再作成後は "tilePaneHeight" メッセージで復元される。
  // 契約: monitorWebviewMessages.ts の setTilePaneHeight / tilePaneHeight)。
  vscode.setState(Object.assign({}, vscode.getState(), { tilePaneHeight: desiredTilePaneHeight }));
  vscode.postMessage({ type: 'setTilePaneHeight', value: desiredTilePaneHeight });
}

// host からの復元値(sendInitialState)を反映する。「デバイス」タブ非表示中は描画が no-op のため、
// desired だけ更新して次の switchTab の reapplyTilePaneHeight で反映されるようにする。
export function setTilePaneHeight(height) {
  if (typeof height !== 'number' || !(height > 0)) {
    return;
  }
  desiredTilePaneHeight = height;
  reapplyTilePaneHeight();
}

reapplyTilePaneHeight();
window.addEventListener('resize', () => reapplyTilePaneHeight());

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
