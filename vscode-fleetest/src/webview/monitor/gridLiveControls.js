// グリッドビュー(1台だけ選択したときの拡大表示)のライブ操作: ツールバー(ホーム・タスク切替・拡大・縮小・
// 折りたたみ機なら折りたたむ・開く)と
// 画面の操作(クリック = タップ / Option+クリック = ダブルタップ / Shift+ドラッグ = 軌跡)。送り先は host の
// MonitorLiveController.handleGridAction(ライブ操作タブと同じ serve。選択中のデバイスが違えば切り替える)。
// 契約: monitorWebviewMessages.ts の gridLiveAction / liveModel.ts の GridLiveAction・gridActionError。
// ツールバーの DOM は monitorHtml.ts(#grid-live-controls。文言は host 側 t() 済み)が持ち、ここで
// 1台表示の .lane-preview の末尾へ移す(laneLog.js の updateLaneVisibility が syncGridLiveControls を呼ぶ)。
// 画面(絵)の上のダブルクリックは2回のタップで、「このデバイスのみ選択」の切り替えは絵の外側だけ
// (laneLog.js が isGridLiveScreenTarget で除く)。素のドラッグ(スワイプ)・長押しは送らない。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { thinTracePoints } from './traceThinning.js';
import { setHoverTip } from './hoverTip.js';
import { liveRemoteTargetFor } from './deviceTiles.js';
import { DRAG_MIN_PX, TRACE_MAX_MS } from './liveTab.js';
import { relayoutPreviewsForResize } from './laneLog.js';
import { bindFoldButtons } from './foldButtons.js';

const parking = document.getElementById('grid-live-parking');
const controls = document.getElementById('grid-live-controls');
const errorEl = document.getElementById('grid-live-error');
const traceIndicator = document.getElementById('grid-live-trace-indicator');
const buttons = [...controls.querySelectorAll('button')];

const svgNS = 'http://www.w3.org/2000/svg';
const dragOverlay = document.createElementNS(svgNS, 'svg');
dragOverlay.setAttribute('class', 'grid-live-drag-overlay');
dragOverlay.setAttribute('aria-hidden', 'true');
const dragTrace = document.createElementNS(svgNS, 'polyline');
const dragStartDot = document.createElementNS(svgNS, 'circle');
dragStartDot.setAttribute('r', '6');
dragOverlay.append(dragTrace, dragStartDot);

// 操作の対象(1台表示のデバイス)。1台表示でない間は null
let target = null;
// ライブ操作が今つないでいるデバイス(host の devices.selectedId)。actionError はこれが target と
// 一致するときだけ出す(ライブ操作タブで別のデバイスを操作した失敗をここに出さない)
let liveSelectedId = null;
let busy = false;
let dragStart = null;

/** id: 1台表示のデバイス(1台表示でなければ null)。previewEl: その拡大表示の .lane-preview */
export function syncGridLiveControls(id, previewEl) {
  if (target && (target.id !== id || target.previewEl !== previewEl)) {
    cancelDrag();
    target.previewEl.removeEventListener('pointerdown', handlePointerDown);
    parking.appendChild(controls);
    dragOverlay.remove();
    target = null;
    showError('');
    refreshFoldButtons();
  }
  if (id === null || !previewEl) {
    return;
  }
  if (!target) {
    target = { id, previewEl };
    previewEl.addEventListener('pointerdown', handlePointerDown);
    refreshFoldButtons();
  }
  // 拡大表示は作り直すときに中身を空にする(deviceTiles.js の attachDeviceMirror)ので毎回見る
  if (controls.parentElement !== previewEl) {
    previewEl.appendChild(controls);
  }
  if (dragOverlay.parentElement !== previewEl) {
    previewEl.appendChild(dragOverlay);
  }
}

/** el が1台表示の絵(操作を受ける画面)の中か。laneLog.js のダブルクリック(選択の切り替え)が除くのに使う */
export function isGridLiveScreenTarget(el) {
  return !!target && el instanceof Element && target.previewEl.contains(el) && !!el.closest('.lane-preview-media');
}

/** host からの live メッセージ(main.js が liveTab.js と両方へ配る)。 */
export function applyGridLiveMessage(message) {
  switch (message.type) {
    case 'devices':
      liveSelectedId = message.selectedId ?? null;
      break;
    case 'busy':
      busy = !!message.busy;
      for (const button of buttons) { button.disabled = busy; }
      break;
    case 'actionError':
      if (target && liveSelectedId === target.id) {
        showError(message.message || '', !!message.neutral);
      }
      break;
    case 'gridActionError':
      if (target && message.id === target.id) {
        showError(message.message);
      }
      break;
  }
}

function showError(text, neutral = false) {
  if (errorEl.textContent === text && errorEl.classList.contains('neutral') === neutral) {
    return;
  }
  errorEl.textContent = text;
  errorEl.classList.toggle('neutral', neutral);
  // 行の出し入れで拡大表示の固定費(高さ)が変わる
  relayoutPreviewsForResize();
}

function postAction(action) {
  if (!target || busy) {
    return;
  }
  showError('');
  const remote = liveRemoteTargetFor(target.id);
  vscode.postMessage({ type: 'gridLiveAction', id: target.id, action, ...(remote ? { remote } : {}) });
}

document.getElementById('grid-live-btn-home').addEventListener('click', () => postAction({ type: 'home' }));
document.getElementById('grid-live-btn-app-switcher').addEventListener('click', () => postAction({ type: 'appSwitcher' }));
document.getElementById('grid-live-btn-zoom-in').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: true }));
document.getElementById('grid-live-btn-zoom-out').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: false }));
const refreshFoldButtons = bindFoldButtons(
  buttons.filter((button) => button.dataset.fold),
  () => target?.id ?? null,
  (state) => postAction({ type: 'fold', state }),
);
// ボタンの押下を拡大表示のダブルクリック(選択の切り替え)へ伝えない
controls.addEventListener('dblclick', (event) => event.stopPropagation());

// 軌跡の表示灯: Shift を押している間だけ点ける(liveTab.js の setTraceIndicator と同じ)
setHoverTip(traceIndicator, traceIndicator.title);
function setTraceIndicator(on) {
  traceIndicator.classList.toggle('active', !!on);
}
window.addEventListener('keydown', (event) => { if (event.key === 'Shift') { setTraceIndicator(true); } });
window.addEventListener('keyup', (event) => { if (event.key === 'Shift') { setTraceIndicator(false); } });
window.addEventListener('blur', () => setTraceIndicator(false));

function clampToRect(event, rect) {
  return {
    x: Math.min(Math.max(event.clientX - rect.left, 0), rect.width),
    y: Math.min(Math.max(event.clientY - rect.top, 0), rect.height),
  };
}

function handlePointerDown(event) {
  if (event.button !== 0 || !target) {
    return;
  }
  const media = event.target instanceof Element ? event.target.closest('.lane-preview-media') : null;
  if (!media) {
    return;
  }
  // 絵の上の押下は操作として扱う(テキスト選択を始めない)
  event.preventDefault();
  event.stopPropagation();
  if (busy) {
    return;
  }
  const rect = media.getBoundingClientRect();
  if (!(rect.width > 0) || !(rect.height > 0)) {
    return;
  }
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  // **押した時点の修飾キーを採る**(liveTab.js の handleScreenPointerDown と同じ理由)
  dragStart = {
    id: target.id, media, pointerId: event.pointerId, downAt: performance.now(), x, y,
    doubleTap: event.altKey, trace: event.shiftKey, moved: false,
    points: [{ x, y, t: 0 }],
  };
  if (dragStart.trace) {
    placeOverlay(rect);
    updateOverlay(x, y);
  }
}

// 軌跡の SVG を絵の矩形にぴったり重ねる(.lane-preview の padding box 基準)
function placeOverlay(mediaRect) {
  const host = target.previewEl;
  const hostRect = host.getBoundingClientRect();
  dragOverlay.style.left = (mediaRect.left - hostRect.left - host.clientLeft) + 'px';
  dragOverlay.style.top = (mediaRect.top - hostRect.top - host.clientTop) + 'px';
  dragOverlay.style.width = mediaRect.width + 'px';
  dragOverlay.style.height = mediaRect.height + 'px';
  dragOverlay.setAttribute('viewBox', `0 0 ${mediaRect.width} ${mediaRect.height}`);
}

function updateOverlay(x, y) {
  dragStartDot.setAttribute('cx', dragStart.x);
  dragStartDot.setAttribute('cy', dragStart.y);
  dragTrace.setAttribute('points', dragStart.points.map((p) => p.x + ',' + p.y).concat([x + ',' + y]).join(' '));
  dragOverlay.classList.add('visible');
}

function cancelDrag() {
  dragStart = null;
  dragOverlay.classList.remove('visible');
}

window.addEventListener('pointermove', (event) => {
  setTraceIndicator(event.shiftKey);
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const rect = dragStart.media.getBoundingClientRect();
  const { x, y } = clampToRect(event, rect);
  if (!dragStart.moved && Math.hypot(x - dragStart.x, y - dragStart.y) >= DRAG_MIN_PX) {
    dragStart.moved = true;
  }
  if (!dragStart.trace) {
    return;
  }
  const elapsed = performance.now() - dragStart.downAt;
  if (elapsed > TRACE_MAX_MS && dragStart.moved) {
    // なぞっている最中に上限を超えたら中止して言う(離すまで気付けないと操作が無駄になる)
    cancelDrag();
    showError(t('wvMonitor.live.traceTooLong', { max: TRACE_MAX_MS / 1000 }));
    return;
  }
  dragStart.points.push({ x, y, t: Math.round(elapsed) });
  updateOverlay(x, y);
});

window.addEventListener('pointerup', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const start = dragStart;
  cancelDrag();
  if (!target || target.id !== start.id) {
    return;
  }
  const rect = start.media.getBoundingClientRect();
  const { x, y } = clampToRect(event, rect);
  const display = { displayWidth: rect.width, displayHeight: rect.height };
  if (Math.hypot(x - start.x, y - start.y) < DRAG_MIN_PX) {
    // 動かさずに離した: Option ならダブルタップ、それ以外はタップ(Shift だけのクリックもタップ = ライブ操作タブと同じ)
    if (start.doubleTap) {
      postAction({ type: 'doubleTapPoint', clickX: x, clickY: y, ...display });
    } else {
      postAction({ type: 'tapPoint', clickX: x, clickY: y, ...display });
    }
  } else if (start.trace) {
    const endT = Math.max(1, Math.round(performance.now() - start.downAt));
    postAction({
      type: 'tracePoints',
      points: thinTracePoints(start.points.concat([{ x, y, t: endT }])),
      ...display,
    });
  }
});

window.addEventListener('pointercancel', () => cancelDrag());
