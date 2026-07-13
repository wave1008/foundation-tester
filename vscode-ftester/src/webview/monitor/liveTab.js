// モニターパネル「ライブ操作」タブ(#panel-live)。main.js が applyLiveMessage を message
// ディスパッチャに組み込む。host への送信は type:'live' の封筒で包む(対向: src/liveModel.ts の
// LiveWebviewEnvelope、処理は src/monitorLiveController.ts)。

import { vscode } from './vscodeApi.js';
import { activateTab } from './tabs.js';
import { clampMenuPosition } from './deviceTiles.js';

function post(message) {
  vscode.postMessage({ type: 'live', message });
}

const deviceSelect = document.getElementById('live-device-select');
const deviceWarning = document.getElementById('live-device-warning');
const busyLabel = document.getElementById('live-busy-label');
const banner = document.getElementById('live-banner');

const screenshot = document.getElementById('live-screenshot');
const screenshotPane = document.getElementById('live-screenshot-pane');
const screenshotActions = document.getElementById('live-screenshot-actions');
const screenshotWrap = document.getElementById('live-screenshot-wrap');
const hoverBox = document.getElementById('live-hover-box');
const screenshotPlaceholder = document.getElementById('live-screenshot-placeholder');
const dragOverlay = document.getElementById('live-drag-overlay');
const dragLine = document.getElementById('live-drag-line');
const dragStartDot = document.getElementById('live-drag-start');
const connOverlay = document.getElementById('live-conn-overlay');
const connDetail = document.getElementById('live-conn-detail');
const busyOverlay = document.getElementById('live-busy-overlay');
const busyMessage = document.getElementById('live-busy-message');

const typeTextInput = document.getElementById('live-type-text');
const typeRefHint = document.getElementById('live-type-ref-hint');
const actionError = document.getElementById('live-action-error');
const elementsList = document.getElementById('live-elements-list');

const appProfileSelect = document.getElementById('live-app-profile-select');
const autoInstallCheckbox = document.getElementById('live-record-autoinstall');
const recordBtn = document.getElementById('live-btn-record');
const recordStatus = document.getElementById('live-record-status');
// 画像右クリックの開始/終了メニュー(#live-btn-record と同じ start/stop フローを流す)。
const recordMenu = document.getElementById('live-record-menu');
const recordMenuStart = document.getElementById('live-record-menu-start');
const recordMenuStop = document.getElementById('live-record-menu-stop');
let recordMenuOpen = false;

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
// host からの 'recording' メッセージのみが更新する(host が唯一の真実。ボタン押下では変えない)。
let recording = false;
// テストコード生成中(stopRecord→gen-scenario 完了まで)。この間は「レコーディング終了」を非活性表示。
let generating = false;
// 選択可能なアプリプロファイルの有無(applyAppProfiles が更新)。無い間は開始不可。
let hasAppProfile = false;

const busyButtons = [
  'live-btn-refresh-devices', 'live-btn-refresh-snapshot',
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

// ---- レコーディング(対向: monitorLiveController.ts / liveModel.ts) --------------

function applyAppProfiles(profiles, selectedId) {
  appProfileSelect.innerHTML = '';
  hasAppProfile = profiles.length > 0;
  if (!hasAppProfile) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '(アプリプロファイルなし)';
    opt.disabled = true;
    opt.selected = true;
    appProfileSelect.appendChild(opt);
    updateRecordButton();
    return;
  }
  for (const profile of profiles) {
    const opt = document.createElement('option');
    opt.value = profile;
    opt.textContent = profile;
    appProfileSelect.appendChild(opt);
  }
  appProfileSelect.value = selectedId && profiles.includes(selectedId) ? selectedId : profiles[0];
  updateRecordButton();
}

function applyRecording(active, isGenerating) {
  recording = active;
  generating = !!isGenerating;
  updateRecordButton();
}

// ボタンの文言・活性を recording/generating/hasAppProfile から一元的に決める。
// - 生成中(generating): 「レコーディング終了」を非活性で表示(gen-scenario 完了まで)。
// - 録画中(recording): 「レコーディング終了」を活性(終了操作を妨げない)。
// - 停止中: 「レコーディング開始」。選択可能なプロファイルが無ければ非活性。
function updateRecordButton() {
  const showStop = recording || generating;
  recordBtn.textContent = showStop ? 'レコーディング終了' : 'レコーディング開始';
  recordBtn.classList.toggle('recording', showStop);
  recordBtn.disabled = generating || (!recording && !hasAppProfile);
  appProfileSelect.disabled = recording || generating;
  autoInstallCheckbox.disabled = recording || generating;
  updateRecordMenuItems();
}

// 画像右クリックメニューの開始/終了の活性を updateRecordButton と同条件で同期(開いている間に
// 状態が変わっても追随する)。開始=停止中かつ生成中でなくプロファイル有り、終了=録画中かつ生成中でない。
function updateRecordMenuItems() {
  recordMenuStart.disabled = recording || generating || !hasAppProfile;
  recordMenuStop.disabled = !recording || generating;
  recordMenuStart.title = (!recording && !generating && !hasAppProfile) ? 'アプリプロファイルが必要です' : '';
}

recordBtn.addEventListener('click', () => {
  if (generating) { return; } // 生成中は非活性だが二重防御(押下しても何もしない)
  if (recording) {
    post({ type: 'stopRecord' });
  } else {
    post({ type: 'startRecord', appProfile: appProfileSelect.value, autoInstall: autoInstallCheckbox.checked });
  }
});

// 画像上で右クリック → 開始/終了メニュー。stopPropagation で document の contextmenu→閉じるを抑止
// (このメニュー自身は即閉じない)。start/stop は recordBtn と同一フロー。
screenshotWrap.addEventListener('contextmenu', (event) => {
  event.preventDefault();
  event.stopPropagation();
  updateRecordMenuItems();
  recordMenu.classList.add('visible');
  clampMenuPosition(recordMenu, event.clientX, event.clientY);
  recordMenuOpen = true;
});
function closeLiveRecordMenu() {
  if (!recordMenuOpen) { return; }
  recordMenuOpen = false;
  recordMenu.classList.remove('visible');
}
recordMenuStart.addEventListener('click', (event) => {
  event.stopPropagation();
  if (recordMenuStart.disabled) { return; }
  post({ type: 'startRecord', appProfile: appProfileSelect.value, autoInstall: autoInstallCheckbox.checked });
  closeLiveRecordMenu();
});
recordMenuStop.addEventListener('click', (event) => {
  event.stopPropagation();
  if (recordMenuStop.disabled) { return; }
  post({ type: 'stopRecord' });
  closeLiveRecordMenu();
});
// 閉じる契機(deviceTiles.js の device-op-menu と同じ組。scroll は capture で子要素のスクロールも拾う)。
document.addEventListener('click', (event) => {
  if (recordMenuOpen && !recordMenu.contains(event.target)) { closeLiveRecordMenu(); }
});
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') { closeLiveRecordMenu(); } });
document.addEventListener('scroll', () => closeLiveRecordMenu(), true);
window.addEventListener('resize', () => closeLiveRecordMenu());
document.addEventListener('contextmenu', () => closeLiveRecordMenu());

// ---- スクリーンショット(クリック=タップ、ドラッグ=スワイプ、要素ホバー=枠オーバーレイ) ------

// 画像を上寄せ・スクロールなしで収める。frame は内容フィット(flex:0 0 auto)で画像実寸に縮むため
// frame 自体の高さは画像に依存し測れない(循環する)。代わりに高さが flex で確定する
// #live-screenshot-pane を実測し、そこから actions 高と pane の gap を引いた残りを画像 max-height に
// する。object-fit は使えない(overlay が inset:0 で wrap に貼り付き、タップ座標も
// img.getBoundingClientRect() 前提のため、要素ボックスを実画像サイズに保つ必要がある)。
const SCREENSHOT_WRAP_BORDER = 2; // .screenshot-wrap の上下ボーダー合計(px)。CSS と一致させること
const SCREENSHOT_PANE_GAP = 6;    // .screenshot-pane の gap(px)。CSS と一致させること
function fitScreenshot() {
  const paneH = screenshotPane.clientHeight;
  if (paneH === 0) { return; } // タブ非表示中(display:none)は測れないので触らない
  const avail = paneH - screenshotActions.offsetHeight - SCREENSHOT_PANE_GAP - SCREENSHOT_WRAP_BORDER;
  const maxH = Math.max(40, avail);
  screenshot.style.maxHeight = maxH + 'px';
  // pane 幅をフィット後の画像表示幅に合わせて縮める → 右隣の control-pane(要素一覧)が画像直後へ
  // 左寄せで並ぶ(伸ばすと右端へ押しやられる)。flex-basis:auto の max-content が画像の自然幅になる
  // 実装差(Chromium)を避けるため確定値を JS で入れる。naturalWidth は load 後のみ有効なので
  // screenshot の 'load' でも再実行する。未ロード時は cap を外し placeholder 幅(min-width)に委ねる。
  if (screenshot.naturalWidth > 0 && screenshot.naturalHeight > 0) {
    const dispH = Math.min(maxH, screenshot.naturalHeight); // 等倍を上限に(拡大しない)
    const dispW = dispH * screenshot.naturalWidth / screenshot.naturalHeight;
    screenshotPane.style.maxWidth = Math.ceil(dispW + SCREENSHOT_WRAP_BORDER) + 'px';
  } else {
    screenshotPane.style.maxWidth = '';
  }
}
// pane の高さは flex で決まり画像内容に依存しない(=maxHeight/maxWidth 変更で再発火しない)ため無限ループ無し。
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(fitScreenshot).observe(screenshotPane);
}
window.addEventListener('resize', fitScreenshot);
// data URI のデコードは非同期で src セット直後は naturalWidth=0。load 後に幅ハグを確定させる。
screenshot.addEventListener('load', fitScreenshot);

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
  fitScreenshot();
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
function submitTypeText() {
  showActionError('');
  post({ type: 'typeText', text: typeTextInput.value, ref: selectedRef });
  // 送信したら入力欄をクリアする(post は value を同期読みするので後でクリアしてよい)。
  typeTextInput.value = '';
}
document.getElementById('live-btn-type').addEventListener('click', submitTypeText);
// Enter で送信。IME変換中(日本語変換の確定)の Enter は送信しない: isComposing が true、
// 環境により keyDown が keyCode 229(IME処理中)で届くため両方を除外する。busy 中は
// 「入力」ボタンが非活性なので Enter でも送らない(挙動をボタンと揃える)。
typeTextInput.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229) { return; }
  if (busy) { return; }
  event.preventDefault();
  submitTypeText();
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
    case 'appProfiles':
      applyAppProfiles(message.profiles, message.selectedId);
      break;
    case 'recording':
      applyRecording(!!message.active, !!message.generating);
      break;
    case 'recordStatus':
      recordStatus.textContent = message.message;
      break;
    case 'busyOverlay':
      if (message.message) {
        busyMessage.textContent = message.message;
        busyOverlay.classList.add('visible');
      } else {
        busyOverlay.classList.remove('visible');
        busyMessage.textContent = '';
      }
      break;
    case 'focusTypeInput':
      // 画像上のテキスト入力欄をタップした直後(host が判定して送る)。既存テキストは選択し、
      // そのまま打鍵で置き換えられるようにする。
      typeTextInput.focus();
      typeTextInput.select();
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
    post({ type: 'refreshAppProfiles' });
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
