// desiredTilePaneHeight=ユーザー意図(ドラッグ・host復元のみで更新、永続化対象)、
// tilePaneHeight=表示用クランプ済み値。分離しないと、パネル表示切替中の一時的に小さい
// レイアウトで resize が走った際にユーザー意図まで最小値へ潰される(実害: エディタ開閉で
// セパレーターが最小位置にリセット)。tabs.js からは reapplyTilePaneHeight を呼ぶ。

import { vscode, persistedState } from './vscodeApi.js';
import { toolbar, banner, devicesPanel, tilePane, splitter, btnFleetVisible } from './domRefs.js';
import { t } from '../i18n.js';
import { setHoverTip } from './hoverTip.js';
import { setLineViewHiddenForWaiting } from './waitingNote.js';
import { relayoutTiles } from './deviceTiles.js';

// setState/getStateにも保存し、パネル再表示時に復元する。出力ペインはflexの残りスペースを
// 自動占有するため個別管理は不要。

const MIN_PANE_HEIGHT = 120;

// 保存値が無いときのラインビューの高さ = 表示エリア(スプリット領域)の 20%(ユーザー決定)。
// **領域が測れた最初の描画で決める**(読み込み時点では「テスト実行」タブが未表示で測れないことがあり、
// そこで決めると代わりの値が残る)。
const DEFAULT_TILE_PANE_RATIO = 0.2;

// ---- ラインビューの表示トグル(ツールバー右端のグループの先頭・既定 表示) ----
// 既定が表示なので「!== false」(ホスト側 monitorPanel.ts の既定 true と揃える。片方だけ変えない)。
let fleetVisible = persistedState.fleetVisible !== false;

// null = 保存値が無い(最初の描画で DEFAULT_TILE_PANE_RATIO から決める)
let desiredTilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : null;
let tilePaneHeight = desiredTilePaneHeight ?? 0;

// document.body.clientHeight だとタブバー分ずれるため、「テスト実行」タブパネル自身の
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

// 「テスト実行」タブ非表示(display:none)の間はdevicesPanel.clientHeightが0になり、誤って
// 最小値にクランプしてしまうため何もせず抜ける(タブ復帰時にswitchTabが呼び直す)。
// ラインビュー非表示の間も同じ理由で抜ける(領域が測れない)。
function splitAreaHidden() {
  return !fleetVisible || devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null;
}

function renderTilePaneHeight() {
  if (desiredTilePaneHeight === null) {
    desiredTilePaneHeight = Math.round(availableSplitHeight() * DEFAULT_TILE_PANE_RATIO);
  }
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

// host からの復元値(sendInitialState)を反映する。「テスト実行」タブ非表示中は描画が no-op のため、
// desired だけ更新して次の switchTab の reapplyTilePaneHeight で反映されるようにする。
export function setTilePaneHeight(height) {
  if (typeof height !== 'number' || !(height > 0)) {
    return;
  }
  desiredTilePaneHeight = height;
  reapplyTilePaneHeight();
}

function renderFleetVisible() {
  devicesPanel.classList.toggle('fleet-hidden', !fleetVisible);
  setLineViewHiddenForWaiting(!fleetVisible);
  btnFleetVisible.classList.toggle('toggled', fleetVisible);
  btnFleetVisible.setAttribute('aria-pressed', fleetVisible ? 'true' : 'false');
  const label = t(fleetVisible ? 'wvMonitor.toolbar.hideFleet' : 'wvMonitor.toolbar.showFleet');
  setHoverTip(btnFleetVisible, label);
  btnFleetVisible.setAttribute('aria-label', label);
}

function applyFleetVisible(visible) {
  fleetVisible = visible;
  renderFleetVisible();
  // 表示へ戻したときに現レイアウトで高さを取り直す(隠れている間の resize は splitAreaHidden で素通り)
  reapplyTilePaneHeight();
}

btnFleetVisible.addEventListener('click', () => {
  applyFleetVisible(!fleetVisible);
  // 契約: monitorWebviewMessages.ts の setFleetVisible / fleetVisible(tilePaneHeight と同じ二重保存)。
  vscode.setState(Object.assign({}, vscode.getState(), { fleetVisible }));
  vscode.postMessage({ type: 'setFleetVisible', value: fleetVisible });
});

export function isFleetVisible() {
  return fleetVisible;
}

// host からの復元値(sendInitialState)。
export function setFleetVisible(visible) {
  if (typeof visible !== 'boolean') {
    return;
  }
  applyFleetVisible(visible);
}

renderFleetVisible();
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
  applyTilePaneHeight(splitterStartHeight + event.clientY - splitterStartY);
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
