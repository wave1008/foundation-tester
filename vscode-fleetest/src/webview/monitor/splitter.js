// desiredTilePaneHeight=ユーザー意図(ドラッグ・host復元のみで更新、永続化対象)、
// tilePaneHeight=表示用クランプ済み値。分離しないと、パネル表示切替中の一時的に小さい
// レイアウトで resize が走った際にユーザー意図まで最小値へ潰される(実害: エディタ開閉で
// セパレーターが最小位置にリセット)。tabs.js からは reapplyTilePaneHeight を呼ぶ。

import { vscode, persistedState } from './vscodeApi.js';
import { toolbar, banner, devicesPanel, tilePane, splitter, grid, btnAutoFit } from './domRefs.js';
import { relayoutTiles, setTileLayoutObserver } from './deviceTiles.js';
import { computeFitPaneHeight } from './tileFitModel.js';

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
// auto-fit が ON のときだけは desired ごと「ちょうど収まる高さ」へ置き換える(OFF にした
// 瞬間の見た目を保つため。以後はその高さが手動調整の起点になる)。
export function reapplyTilePaneHeight() {
  if (splitAreaHidden()) {
    return;
  }
  if (autoFitEnabled && !autoFitSuspendedByDrag) {
    const fitted = computeFitTilePaneHeight();
    if (fitted !== null) {
      desiredTilePaneHeight = clampTilePaneHeight(fitted);
    }
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

// ---- auto-fit(ツールバー右端のトグル・既定 ON) ----
// ON の間、タイルが1行(.grid は flex-wrap:nowrap)で横スクロールせずちょうど収まる高さへ
// セパレーターを自動で置く。明示的に OFF にしたときだけ完全手動(従来ドラッグのみ)。
// 再計算の契機: 台数変化・アスペクト比確定(deviceTiles.js の tileLayoutObserver)/
// リサイズ・タブ復帰(reapplyTilePaneHeight)。
// 既定 ON のため「=== true」ではなく「!== false」(未保存=ON。ホスト側の既定も
// monitorPanel.ts で true に揃えている。片方だけ変えない)。
let autoFitEnabled = persistedState.tileAutoFit !== false;
// 手動ドラッグは OFF ではなく「一時停止」: リサイズ等では手動位置を保ち、台数が変わったら
// 自動で再フィットして追従を再開する(ユーザー要件 2026-07-30)。永続化しない
// (パネル再表示では ON に戻ってフィットし直す)。
let autoFitSuspendedByDrag = false;

// 実測して computeFitPaneHeight(tileFitModel.js)へ渡すだけ。定数(padding/border/gap)は
// 持たず全て実測する(style.css を変えたときに片方だけ古くなるのを防ぐ)。
function computeFitTilePaneHeight() {
  const tileEls = grid.querySelectorAll('.tile');
  const gridStyle = getComputedStyle(grid);
  const measuredTiles = [];
  for (const tileEl of tileEls) {
    const frame = tileEl.querySelector('.frame-wrap');
    if (!frame) {
      return null;
    }
    const imageWidth = frame.getBoundingClientRect().width;
    measuredTiles.push({
      imageWidth,
      chromeWidth: tileEl.getBoundingClientRect().width - imageWidth,
    });
  }
  return computeFitPaneHeight({
    paneHeight: tilePaneHeight,
    imageHeight: parseFloat(gridStyle.getPropertyValue('--tile-image-h')),
    gridWidth: grid.clientWidth,
    gap: parseFloat(gridStyle.columnGap),
    tiles: measuredTiles,
  });
}

function renderAutoFitButton() {
  btnAutoFit.classList.toggle('toggled', autoFitEnabled);
  btnAutoFit.classList.toggle('suspended', autoFitEnabled && autoFitSuspendedByDrag);
  btnAutoFit.setAttribute('aria-pressed', autoFitEnabled ? 'true' : 'false');
}

function persistAutoFit() {
  // tilePaneHeight と同じ二重保存(即時復元用の setState + パネル再作成に耐える host 側)。
  // 契約: monitorWebviewMessages.ts の setTileAutoFit / tileAutoFit。
  vscode.setState(Object.assign({}, vscode.getState(), { tileAutoFit: autoFitEnabled }));
  vscode.postMessage({ type: 'setTileAutoFit', value: autoFitEnabled });
}

// 手動ドラッグ中に呼ぶ一時停止。ここで高さは触らない(ドラッグ側がそのまま反映する)。
// OFF にはしない(台数変化で再開するため。完全 OFF はトグルの明示操作のみ)。
function suspendAutoFitForManualDrag() {
  if (!autoFitEnabled || autoFitSuspendedByDrag) {
    return;
  }
  autoFitSuspendedByDrag = true;
  renderAutoFitButton();
}

btnAutoFit.addEventListener('click', () => {
  autoFitEnabled = !autoFitEnabled;
  autoFitSuspendedByDrag = false;
  renderAutoFitButton();
  reapplyTilePaneHeight();
  persistAutoFit();
  if (!autoFitEnabled) {
    // OFF にした時点の高さを手動位置として残す(次回復元はこの高さから始まる)。
    persistTilePaneHeight();
  }
});

// reason: 'deviceCount'(台数変化)| 'aspect'(アスペクト比確定)。台数変化だけは
// ドラッグの一時停止を解除して再フィットする(フレーム到着のたびに来る aspect で解除すると
// 手動位置がすぐ戻されてしまう)。
setTileLayoutObserver((reason) => {
  if (!autoFitEnabled) {
    return;
  }
  if (reason === 'deviceCount' && autoFitSuspendedByDrag) {
    autoFitSuspendedByDrag = false;
    renderAutoFitButton();
  }
  if (autoFitSuspendedByDrag) {
    return;
  }
  reapplyTilePaneHeight();
});

// host からの復元値(sendInitialState)。
export function setTileAutoFit(enabled) {
  if (typeof enabled !== 'boolean') {
    return;
  }
  autoFitEnabled = enabled;
  autoFitSuspendedByDrag = false;
  renderAutoFitButton();
  reapplyTilePaneHeight();
}

renderAutoFitButton();
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
  const delta = event.clientY - splitterStartY;
  // 実際に動いたときだけ一時停止する(押しただけ・0px のドラッグでは何もしない)。
  // 停止しないと以後の再計算でセパレーターが手動位置から戻ってしまう。
  if (delta !== 0) {
    suspendAutoFitForManualDrag();
  }
  applyTilePaneHeight(splitterStartHeight + delta);
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
