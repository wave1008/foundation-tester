// desiredTilePaneHeight/desiredLogPaneHeight=ユーザー意図(ドラッグ・host復元のみで更新、永続化対象)、
// tilePaneHeight/logPaneHeight=表示用クランプ済み値。分離しないと、パネル表示切替中の一時的に小さい
// レイアウトで resize が走った際にユーザー意図まで最小値へ潰される(実害: エディタ開閉で
// セパレーターが最小位置にリセット)。tabs.js からは reapplyTilePaneHeight を呼ぶ。
//
// 縦の並びは toolbar/banner/line-view-header → tile-pane(ラインビュー) → splitter →
// log-pane(実行ログビュー) → splitter-log → output-pane(グリッドビュー。flex:1 1 auto で残りを占有)。
// tile-pane と log-pane は明示高さ(このモジュールが計算)・output-pane は残りを自動で占める。

import { vscode, persistedState } from './vscodeApi.js';
import {
  toolbar, banner, devicesPanel, tilePane, splitter, lineViewHeader, lineViewToggle, lineViewTitle,
  logPane, logViewHeader, logViewToggle, splitterLog, outputPane, gridViewHeader, gridViewToggle, runBoard,
} from './domRefs.js';
import { clampHeight, tilePaneLimits, logPaneLimits } from './paneLayoutModel.js';
import { t } from '../i18n.js';
import { setLineViewHiddenForWaiting, setGridViewHiddenForWaiting } from './waitingNote.js';
import { relayoutTiles } from './deviceTiles.js';

// setState/getStateにも保存し、パネル再表示時に復元する。

const MIN_PANE_HEIGHT = 120;

// 保存値が無いときのラインビューの高さ = 表示エリア(スプリット領域)の 20%(ユーザー決定)。
// **領域が測れた最初の描画で決める**(読み込み時点では「デバイスモニター」タブが未表示で測れないことがあり、
// そこで決めると代わりの値が残る)。
const DEFAULT_TILE_PANE_RATIO = 0.2;

// 保存値が無いときの実行ログビューの高さ = 下部領域(ラインビューとスプリッター2本を引いた残り)の 50%。
const DEFAULT_LOG_PANE_RATIO = 0.5;

// ---- ラインビューの表示トグル(既定 表示) ----
// 既定が表示なので「!== false」(ホスト側 monitorPanel.ts の既定 true と揃える。片方だけ変えない)。
let fleetVisible = persistedState.fleetVisible !== false;

// 実行ログビュー・グリッドビューの開閉(既定 表示。tilePaneHeight/fleetVisible と同じ規律)。
let logViewVisible = persistedState.logViewVisible !== false;
let gridViewVisible = persistedState.gridViewVisible !== false;

// null = 保存値が無い(最初の描画で既定比から決める)
let desiredTilePaneHeight =
  typeof persistedState.tilePaneHeight === 'number' && persistedState.tilePaneHeight > 0
    ? persistedState.tilePaneHeight
    : null;
let tilePaneHeight = desiredTilePaneHeight ?? 0;

let desiredLogPaneHeight =
  typeof persistedState.logPaneHeight === 'number' && persistedState.logPaneHeight > 0
    ? persistedState.logPaneHeight
    : null;
let logPaneHeight = desiredLogPaneHeight ?? 0;

// document.body.clientHeight だとタブバー分ずれるため、「デバイスモニター」タブパネル自身の
// clientHeight を基準にする。3つのペイン(tile-pane / log-pane / output-pane)が分け合う高さなので、
// **その外に居るもの全部**(ツールバー・run ボード・バナー・ラインビューの見出し・スプリッター2本)を引く。
// 畳んで消えているもの(スプリッター)は offsetHeight が 0 なので自動で勘定から外れる。
function availableSplitHeight() {
  const bannerHeight = banner.classList.contains('visible') ? banner.offsetHeight : 0;
  return devicesPanel.clientHeight
    - toolbar.offsetHeight - runBoard.offsetHeight - bannerHeight - lineViewHeader.offsetHeight
    - splitter.offsetHeight - splitterLog.offsetHeight;
}

// ペインが見出し行だけになったときの高さ(見出し + ペインの上下パディング)。**定数を置かず実測する**
// —— style.css の padding を変えたときに片方だけ古くならない。
function paneChromeHeight(pane, header) {
  const style = getComputedStyle(pane);
  return header.offsetHeight + (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
}

function clampTilePaneHeight(height) {
  const bottomChrome = paneChromeHeight(logPane, logViewHeader) + paneChromeHeight(outputPane, gridViewHeader);
  const { min, max } = tilePaneLimits({
    available: availableSplitHeight(),
    bottomChrome,
    minTile: MIN_PANE_HEIGHT,
  });
  return clampHeight(height, min, max);
}

// ラインビュー(tile-pane)を引いた残り。実測(offsetHeight)を使う —— ラインビュー非表示中は
// CSS(.fleet-hidden #tile-pane)が実高さを0にするので、変数(tilePaneHeight)ではなく
// 実測を使うことで隠れている分を二重に引かない。
function bottomAvailableHeight() {
  return availableSplitHeight() - tilePane.offsetHeight;
}

// 下限 = 自分の見出し行だけ・上限 = グリッドビューの見出し行が残る位置(どちらも消さない)。
function clampLogPaneHeight(height) {
  const { min, max } = logPaneLimits({
    bottomAvailable: bottomAvailableHeight(),
    logChrome: paneChromeHeight(logPane, logViewHeader),
    gridChrome: paneChromeHeight(outputPane, gridViewHeader),
  });
  return clampHeight(height, min, max);
}

// 「デバイスモニター」タブ非表示(display:none)の間はdevicesPanel.clientHeightが0になり、誤って
// 最小値にクランプしてしまうため何もせず抜ける(タブ復帰時にswitchTabが呼び直す)。
function panelHidden() {
  return devicesPanel.clientHeight === 0 || devicesPanel.offsetParent === null;
}

// ラインビュー非表示の間も測れないため抜ける。
function splitAreaHidden() {
  return !fleetVisible || panelHidden();
}

function renderTilePaneHeight() {
  if (desiredTilePaneHeight === null) {
    desiredTilePaneHeight = Math.round(availableSplitHeight() * DEFAULT_TILE_PANE_RATIO);
  }
  tilePaneHeight = clampTilePaneHeight(desiredTilePaneHeight);
  tilePane.style.height = tilePaneHeight + 'px';
  relayoutTiles();
  // ラインビューの高さが変わると下部領域(実行ログビュー)の残りも変わる
  reapplyLogPaneHeight();
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

// host からの復元値(sendInitialState)を反映する。「デバイスモニター」タブ非表示中は描画が no-op のため、
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
  // 見出し行(run ボードのヘッダと同じ規律: 文字は常に ▶ で向きは CSS の回転)
  lineViewToggle.dataset.expanded = fleetVisible ? 'true' : 'false';
  lineViewToggle.setAttribute('aria-expanded', fleetVisible ? 'true' : 'false');
  lineViewTitle.textContent = t('wvMonitor.lineView.title');
  const label = t(fleetVisible ? 'wvMonitor.lineView.hide' : 'wvMonitor.lineView.show');
  lineViewToggle.title = label;
  lineViewToggle.setAttribute('aria-label', label);
}

function applyFleetVisible(visible) {
  fleetVisible = visible;
  renderFleetVisible();
  // 表示へ戻したときに現レイアウトで高さを取り直す(隠れている間の resize は splitAreaHidden で素通り)
  reapplyTilePaneHeight();
}

function toggleFleetVisible() {
  applyFleetVisible(!fleetVisible);
  // 契約: monitorWebviewMessages.ts の setFleetVisible / fleetVisible(tilePaneHeight と同じ二重保存)。
  vscode.setState(Object.assign({}, vscode.getState(), { fleetVisible }));
  vscode.postMessage({ type: 'setFleetVisible', value: fleetVisible });
}

// **見出し行はどこを押しても開閉**(run ボードのヘッダと同じ。三角だけだと当たり判定が小さい)。
// トグルは <button> なのでキーボードの Enter/Space も click になり、そのままここへ来る
lineViewHeader.addEventListener('click', toggleFleetVisible);

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

// ---- 実行ログビュー(log-pane)の高さ ----

function renderLogPaneHeight() {
  if (!logViewVisible) {
    // 本体(.lanes-grid/プレースホルダ)は CSS(.log-view-hidden)で隠れるので、高さの指定も外して
    // 見出し行だけの高さへ縮める(desired は保持し、再度開いたときに使う)。
    logPane.style.height = '';
    return;
  }
  if (desiredLogPaneHeight === null) {
    desiredLogPaneHeight = Math.round(bottomAvailableHeight() * DEFAULT_LOG_PANE_RATIO);
  }
  logPaneHeight = clampLogPaneHeight(desiredLogPaneHeight);
  logPane.style.height = logPaneHeight + 'px';
}

export function applyLogPaneHeight(height) {
  if (panelHidden()) {
    return;
  }
  desiredLogPaneHeight = clampLogPaneHeight(height);
  renderLogPaneHeight();
}

export function reapplyLogPaneHeight() {
  if (panelHidden()) {
    return;
  }
  renderLogPaneHeight();
}

function persistLogPaneHeight() {
  vscode.setState(Object.assign({}, vscode.getState(), { logPaneHeight: desiredLogPaneHeight }));
  vscode.postMessage({ type: 'setLogPaneHeight', value: desiredLogPaneHeight });
}

export function setLogPaneHeight(height) {
  if (typeof height !== 'number' || !(height > 0)) {
    return;
  }
  desiredLogPaneHeight = height;
  reapplyLogPaneHeight();
}

// ---- 実行ログビュー・グリッドビューの開閉 ----
// **畳まれていない側が残りを全部使う**(ユーザー決定): 相手が畳まれている間、開いている側の
// flex-grow を有効にする(グリッドビューは既定で flex:1 1 auto なので、実行ログビューが畳まれて
// いれば何もしなくても残りを占める。逆にグリッドビューが畳まれているときだけ実行ログビュー側に
// flex-grow を足す)。

function renderPaneFlex() {
  logPane.style.flex = (!gridViewVisible && logViewVisible) ? '1 1 auto' : '';
  outputPane.style.flex = gridViewVisible ? '' : '0 0 auto';
}

function renderLogViewVisible() {
  devicesPanel.classList.toggle('log-view-hidden', !logViewVisible);
  logViewToggle.dataset.expanded = logViewVisible ? 'true' : 'false';
  logViewToggle.setAttribute('aria-expanded', logViewVisible ? 'true' : 'false');
  const label = t(logViewVisible ? 'wvMonitor.logView.hide' : 'wvMonitor.logView.show');
  logViewToggle.title = label;
  logViewToggle.setAttribute('aria-label', label);
}

function renderGridViewVisible() {
  devicesPanel.classList.toggle('grid-view-hidden', !gridViewVisible);
  setGridViewHiddenForWaiting(!gridViewVisible);
  gridViewToggle.dataset.expanded = gridViewVisible ? 'true' : 'false';
  gridViewToggle.setAttribute('aria-expanded', gridViewVisible ? 'true' : 'false');
  const label = t(gridViewVisible ? 'wvMonitor.gridView.hide' : 'wvMonitor.gridView.show');
  gridViewToggle.title = label;
  gridViewToggle.setAttribute('aria-label', label);
}

function applyLogViewVisible(visible) {
  logViewVisible = visible;
  renderLogViewVisible();
  renderPaneFlex();
  reapplyLogPaneHeight();
}

function applyGridViewVisible(visible) {
  gridViewVisible = visible;
  renderGridViewVisible();
  renderPaneFlex();
  reapplyLogPaneHeight();
}

function toggleLogViewVisible() {
  applyLogViewVisible(!logViewVisible);
  vscode.setState(Object.assign({}, vscode.getState(), { logViewVisible }));
  vscode.postMessage({ type: 'setLogViewVisible', value: logViewVisible });
}

function toggleGridViewVisible() {
  applyGridViewVisible(!gridViewVisible);
  vscode.setState(Object.assign({}, vscode.getState(), { gridViewVisible }));
  vscode.postMessage({ type: 'setGridViewVisible', value: gridViewVisible });
}

logViewHeader.addEventListener('click', toggleLogViewVisible);
gridViewHeader.addEventListener('click', toggleGridViewVisible);

export function setLogViewVisible(visible) {
  if (typeof visible !== 'boolean') {
    return;
  }
  applyLogViewVisible(visible);
}

export function setGridViewVisible(visible) {
  if (typeof visible !== 'boolean') {
    return;
  }
  applyGridViewVisible(visible);
}

// run ボードは開閉で高さが変わる = 3ペインが分け合う残りも変わる。自分が高さを書き換えない
// 相手なので観測しても再入しない(jsdom には ResizeObserver が無いので存在するときだけ)。
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => reapplyPaneHeights()).observe(runBoard);
}

// ラインビュー非表示中は reapplyTilePaneHeight が素通りする(領域が測れない)ので、
// 実行ログビューの再クランプは独立に呼ぶ —— 呼ばないと畳んだ状態で窓を縮めたとき、
// 古い高さのままグリッドビューの見出し行が押し出される。
function reapplyPaneHeights() {
  reapplyTilePaneHeight();
  reapplyLogPaneHeight();
}

renderFleetVisible();
renderLogViewVisible();
renderGridViewVisible();
renderPaneFlex();
reapplyTilePaneHeight();
window.addEventListener('resize', () => reapplyPaneHeights());

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

let splitterLogPointerId = null;
let splitterLogStartY = 0;
let splitterLogStartHeight = 0;

splitterLog.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) {
    return;
  }
  splitterLogPointerId = event.pointerId;
  splitterLogStartY = event.clientY;
  splitterLogStartHeight = logPaneHeight;
  splitterLog.setPointerCapture(event.pointerId);
  splitterLog.classList.add('dragging');
  event.preventDefault();
});
splitterLog.addEventListener('pointermove', (event) => {
  if (splitterLogPointerId !== event.pointerId) {
    return;
  }
  applyLogPaneHeight(splitterLogStartHeight + event.clientY - splitterLogStartY);
});
const endSplitterLogDrag = (event) => {
  if (splitterLogPointerId !== event.pointerId) {
    return;
  }
  splitterLogPointerId = null;
  splitterLog.classList.remove('dragging');
  splitterLog.releasePointerCapture(event.pointerId);
  persistLogPaneHeight();
};
splitterLog.addEventListener('pointerup', endSplitterLogDrag);
splitterLog.addEventListener('pointercancel', endSplitterLogDrag);
