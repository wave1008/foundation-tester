// モニターパネル「ライブ操作」タブ(#panel-live)。main.js が applyLiveMessage を message
// ディスパッチャに組み込む。host への送信は type:'live' の封筒で包む(対向: src/liveModel.ts の
// LiveWebviewEnvelope、処理は src/monitorLiveController.ts)。

import { vscode } from './vscodeApi.js';
import { activateTab } from './tabs.js';

function post(message) {
  vscode.postMessage({ type: 'live', message });
}

const deviceSelect = document.getElementById('live-device-select');
const deviceWarning = document.getElementById('live-device-warning');
const busyLabel = document.getElementById('live-busy-label');
const banner = document.getElementById('live-banner');

const screenshot = document.getElementById('live-screenshot');
const hoverBox = document.getElementById('live-hover-box');
const screenshotPlaceholder = document.getElementById('live-screenshot-placeholder');
const dragOverlay = document.getElementById('live-drag-overlay');
const dragLine = document.getElementById('live-drag-line');
const dragStartDot = document.getElementById('live-drag-start');
const connOverlay = document.getElementById('live-conn-overlay');
const connDetail = document.getElementById('live-conn-detail');

const typeTextInput = document.getElementById('live-type-text');
const typeRefHint = document.getElementById('live-type-ref-hint');
const actionError = document.getElementById('live-action-error');
const elementsList = document.getElementById('live-elements-list');

const STATE_LABEL = {
  connected: '接続済み',
  booted: '起動中',
  offline: '未起動',
  unknown: '状態不明(未確認)',
};

let currentDevices = [];
let lastScreen = null;
let lastElements = [];
let selectedRef = null;
let busy = false;
// frame 受信時の自動全量更新(refreshSnapshot)の一回制御。applySnapshot で false に戻す。
let autoSnapshotRequested = false;

const busyButtons = [
  'live-btn-refresh-devices', 'live-btn-terminate', 'live-btn-refresh-snapshot',
  'live-btn-app-switcher', 'live-btn-home',
  'live-btn-type',
].map((id) => document.getElementById(id));

function setBusy(value) {
  busy = value;
  for (const b of busyButtons) { b.disabled = value; }
  deviceSelect.disabled = value;
  busyLabel.textContent = value ? '処理中...' : '';
}

function showBanner(text) {
  if (!text) { banner.classList.remove('visible'); banner.textContent = ''; return; }
  banner.textContent = text;
  banner.classList.add('visible');
}

function showActionError(text) {
  if (!text) { actionError.classList.remove('visible'); actionError.textContent = ''; return; }
  actionError.textContent = text;
  actionError.classList.add('visible');
}

// ---- デバイス選択 ---------------------------------------------------------------

function updateDeviceWarning() {
  const selected = currentDevices.find((d) => d.id === deviceSelect.value);
  deviceWarning.textContent = selected && selected.state !== 'connected' ? '⚠ 接続されていません' : '';
}

function applyDevices(devices, selectedId) {
  currentDevices = devices;
  deviceSelect.innerHTML = '';
  for (const d of devices) {
    const opt = document.createElement('option');
    opt.value = d.id;
    opt.textContent = d.name + '(' + d.platform + ') - ' + (STATE_LABEL[d.state] || d.state);
    deviceSelect.appendChild(opt);
  }
  if (selectedId) { deviceSelect.value = selectedId; }
  updateDeviceWarning();
}

deviceSelect.addEventListener('change', () => {
  updateDeviceWarning();
  post({ type: 'selectDevice', id: deviceSelect.value });
});

// ---- スクリーンショット(クリック=タップ、ドラッグ=スワイプ、要素ホバー=枠オーバーレイ) ------

// liveModel.ts の frameToDisplayRect と同じ計算(webview は CSP により import 不可のため複製。
// liveModel.ts 側を変更したらここも追随させること)。
function frameToDisplayRect(frame, screen, display) {
  if (screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scaleX = display.width / screen.width;
  const scaleY = display.height / screen.height;
  return {
    x: frame.x * scaleX, y: frame.y * scaleY,
    width: frame.width * scaleX, height: frame.height * scaleY,
  };
}

function applySnapshot(message) {
  lastScreen = message.screen;
  lastElements = message.elements;
  autoSnapshotRequested = false;
  selectedRef = null;
  typeRefHint.textContent = '→ フォーカス中の要素に入力';
  screenshot.src = 'data:image/jpeg;base64,' + message.image;
  screenshot.classList.add('visible');
  screenshotPlaceholder.style.display = 'none';
  hoverBox.style.display = 'none';
  renderElements();
}

// 押下→ほぼ動かさず離す=タップ、動かして離す=ドラッグ(スワイプ)。click は使わない
// (ドラッグ後にも click が発火してタップが重複するため)。座標は画像表示座標のまま送り、
// ポイント座標への変換は host 側(monitorLiveController.ts の pointFromClick)が行う。
// <img> 既定の HTML5 ドラッグ&ドロップ(緑の+コピーカーソル)が pointer イベントを乗っ取るため
// 無効化必須(style.css の -webkit-user-drag: none と対)。
screenshot.draggable = false;
screenshot.addEventListener('dragstart', (event) => event.preventDefault());
const DRAG_MIN_PX = 5;
const LONG_PRESS_MS = 500;
let dragStart = null;

// デバイス側のスワイプは pointerup 時に1回で実行される(XCUITest にタッチ逐次移動 API が無く
// リアルタイム追従は不可)ため、ドラッグ中は構成中のジェスチャを軌跡オーバーレイで見せる。
function updateDragOverlay(start, x, y) {
  dragStartDot.setAttribute('cx', start.x);
  dragStartDot.setAttribute('cy', start.y);
  dragLine.setAttribute('x1', start.x);
  dragLine.setAttribute('y1', start.y);
  dragLine.setAttribute('x2', x);
  dragLine.setAttribute('y2', y);
  dragOverlay.classList.add('visible');
}
function hideDragOverlay() {
  dragOverlay.classList.remove('visible');
}

screenshot.addEventListener('pointerdown', (event) => {
  if (busy || !lastScreen || event.button !== 0) { return; }
  // 既定動作(画像ドラッグ・テキスト選択の開始)の抑止。dragstart 抑止だけでは環境により
  // ネイティブドラッグが始まることがあるため両方必要。
  event.preventDefault();
  const rect = screenshot.getBoundingClientRect();
  dragStart = {
    x: event.clientX - rect.left, y: event.clientY - rect.top, pointerId: event.pointerId,
    downAt: performance.now(), moveAt: null,
  };
  updateDragOverlay(dragStart, dragStart.x, dragStart.y);
  try {
    screenshot.setPointerCapture(event.pointerId);
  } catch {
    // capture 不可でも window 側の pointerup で拾えるため無視してよい
  }
});
window.addEventListener('pointermove', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) { return; }
  const rect = screenshot.getBoundingClientRect();
  const x = Math.min(Math.max(event.clientX - rect.left, 0), rect.width);
  const y = Math.min(Math.max(event.clientY - rect.top, 0), rect.height);
  updateDragOverlay(dragStart, x, y);
  if (dragStart.moveAt === null && Math.hypot(x - dragStart.x, y - dragStart.y) >= DRAG_MIN_PX) {
    dragStart.moveAt = performance.now();
  }
});
// pointerup は window で拾う(capture が効かない環境・画像外で離した場合も取りこぼさない)。
window.addEventListener('pointerup', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) { return; }
  hideDragOverlay();
  const start = dragStart;
  dragStart = null;
  try {
    screenshot.releasePointerCapture(event.pointerId);
  } catch {
    // 未 capture なら何もしない
  }
  if (busy || !lastScreen) { return; }
  const rect = screenshot.getBoundingClientRect();
  // キャプチャ中は画像外で離せるため表示範囲にクランプする
  const endX = Math.min(Math.max(event.clientX - rect.left, 0), rect.width);
  const endY = Math.min(Math.max(event.clientY - rect.top, 0), rect.height);
  const upAt = performance.now();
  if (Math.hypot(endX - start.x, endY - start.y) < DRAG_MIN_PX) {
    const holdMs = Math.max(0, Math.round(upAt - start.downAt));
    if (holdMs >= LONG_PRESS_MS) {
      post({
        type: 'pressPoint',
        clickX: endX, clickY: endY,
        displayWidth: rect.width, displayHeight: rect.height,
        holdMs: holdMs,
      });
    } else {
      post({
        type: 'tapPoint',
        clickX: endX, clickY: endY,
        displayWidth: rect.width, displayHeight: rect.height,
      });
    }
  } else {
    const moveAt = start.moveAt ?? upAt;
    post({
      type: 'dragPoints',
      fromX: start.x, fromY: start.y, toX: endX, toY: endY,
      displayWidth: rect.width, displayHeight: rect.height,
      pressMs: Math.max(0, Math.round(moveAt - start.downAt)),
      dragMs: Math.max(1, Math.round(upAt - moveAt)),
    });
  }
});
window.addEventListener('pointercancel', () => {
  dragStart = null;
  hideDragOverlay();
});

function showHover(element) {
  if (!lastScreen) { return; }
  const rect = screenshot.getBoundingClientRect();
  const box = frameToDisplayRect(element.frame, lastScreen, { width: rect.width, height: rect.height });
  hoverBox.style.left = box.x + 'px';
  hoverBox.style.top = box.y + 'px';
  hoverBox.style.width = box.width + 'px';
  hoverBox.style.height = box.height + 'px';
  hoverBox.style.display = 'block';
}

function hideHover() {
  hoverBox.style.display = 'none';
}

function renderElements() {
  elementsList.innerHTML = '';
  for (const element of lastElements) {
    const row = document.createElement('div');
    row.className = 'element-row';
    row.textContent = element.line;
    row.addEventListener('click', () => {
      if (busy) { return; }
      for (const r of elementsList.querySelectorAll('.element-row')) { r.classList.remove('selected'); }
      row.classList.add('selected');
      selectedRef = element.ref;
      typeRefHint.textContent = '→ ref ' + element.ref + ' に入力';
      post({ type: 'tapRef', ref: element.ref });
    });
    row.addEventListener('mouseenter', () => showHover(element));
    row.addEventListener('mouseleave', hideHover);
    elementsList.appendChild(row);
  }
}

// ---- 操作ボタン ------------------------------------------------------------------

document.getElementById('live-btn-refresh-devices').addEventListener('click', () => {
  post({ type: 'refreshDevices' });
});
document.getElementById('live-btn-refresh-snapshot').addEventListener('click', () => {
  showActionError('');
  post({ type: 'refreshSnapshot' });
});
document.getElementById('live-btn-home').addEventListener('click', () => {
  showActionError('');
  post({ type: 'home' });
});
document.getElementById('live-btn-app-switcher').addEventListener('click', () => {
  showActionError('');
  post({ type: 'appSwitcher' });
});
document.getElementById('live-btn-terminate').addEventListener('click', () => {
  showActionError('');
  post({ type: 'terminate' });
});
document.getElementById('live-btn-type').addEventListener('click', () => {
  showActionError('');
  post({ type: 'typeText', text: typeTextInput.value, ref: selectedRef });
});

// ---- host からのメッセージ(type:'live' 封筒の中身。main.js のディスパッチャから呼ばれる) --------

export function applyLiveMessage(message) {
  switch (message.type) {
    case 'devices':
      applyDevices(message.devices, message.selectedId);
      break;
    case 'banner':
      showBanner(message.message);
      break;
    case 'snapshot':
      applySnapshot(message);
      break;
    case 'frame':
      screenshot.src = 'data:image/jpeg;base64,' + message.image;
      screenshot.classList.add('visible');
      screenshotPlaceholder.style.display = 'none';
      // frame は screen(タップ/ドラッグ座標変換の基準)を持たない。snapshot 未取得のまま frame
      // だけが流れているとポインタ操作が無反応になるため、一度だけ全量更新を要求する
      // (パネル開き直しでライブタブが復元された直後に起きる)。フラグは applySnapshot で戻す。
      if (!lastScreen && !autoSnapshotRequested && !busy) {
        autoSnapshotRequested = true;
        post({ type: 'refreshSnapshot' });
      }
      break;
    case 'actionError':
      showActionError(message.message);
      break;
    case 'busy':
      setBusy(!!message.busy);
      break;
    case 'connection':
      if (message.connected === false) {
        connOverlay.classList.add('visible');
        connDetail.textContent = message.message ?? '';
        screenshot.classList.add('disconnected');
      } else {
        connOverlay.classList.remove('visible');
        connDetail.textContent = '';
        screenshot.classList.remove('disconnected');
      }
      break;
    default:
      break;
  }
}

// 初回タブ活性化時にデバイス一覧を自動取得する(旧ライブ操作パネルの show()→refreshDevices相当。
// tabs.js の switchTab が発火する ft-tab-activated に依存)。
let initialized = false;
document.addEventListener('ft-tab-activated', (event) => {
  if (event.detail.tab === 'live' && !initialized) {
    initialized = true;
    post({ type: 'refreshDevices' });
  }
});

// デバイスタブの右クリック「ライブ操作」(deviceTiles.js が dispatch)。初回自動 refreshDevices は
// 抑止し、host 側 openDevice が一覧取得と選択をまとめて行う。
document.addEventListener('ft-live-open-device', (event) => {
  initialized = true;
  activateTab('live');
  post({ type: 'openDevice', id: event.detail.id });
});

// タブ表示状態を host へ通知(自動フレーム更新のオンオフ。監視元: monitorLiveController.ts)
document.addEventListener('ft-tab-activated', (event) => {
  post({ type: 'visibility', visible: event.detail.tab === 'live' });
});
