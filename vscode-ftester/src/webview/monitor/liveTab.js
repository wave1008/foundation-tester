// モニターパネル「ライブ操作」タブ(#panel-live)。main.js が applyLiveMessage を message
// ディスパッチャに組み込む。host への送信は type:'live' の封筒で包む(対向: src/liveModel.ts の
// LiveWebviewEnvelope、処理は src/monitorLiveController.ts)。

import { vscode } from './vscodeApi.js';

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

const bundleIdInput = document.getElementById('live-bundle-id');
const iosPathInput = document.getElementById('live-ios-path');
const androidPathInput = document.getElementById('live-android-path');
const installHint = document.getElementById('live-install-hint');
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

const busyButtons = [
  'live-btn-refresh-devices', 'live-btn-launch', 'live-btn-terminate', 'live-btn-pick-ios',
  'live-btn-pick-android', 'live-btn-install', 'live-btn-refresh-snapshot', 'live-btn-swipe-up',
  'live-btn-swipe-down', 'live-btn-swipe-left', 'live-btn-swipe-right', 'live-btn-type',
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

function updateInstallHint() {
  const selected = currentDevices.find((d) => d.id === deviceSelect.value);
  const isAndroid = !!selected && selected.platform === 'android';
  installHint.textContent = isAndroid ? '→ Android(.apk)のパスを使用' : '→ iOS(.app)のパスを使用';
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
  updateInstallHint();
}

deviceSelect.addEventListener('change', () => {
  updateDeviceWarning();
  updateInstallHint();
  post({ type: 'selectDevice', id: deviceSelect.value });
});

// ---- スクリーンショット(クリック=タップ、要素ホバー=枠オーバーレイ) -----------------

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
  selectedRef = null;
  typeRefHint.textContent = '→ フォーカス中の要素に入力';
  screenshot.src = 'data:image/jpeg;base64,' + message.image;
  screenshot.classList.add('visible');
  screenshotPlaceholder.style.display = 'none';
  hoverBox.style.display = 'none';
  renderElements();
}

screenshot.addEventListener('click', (event) => {
  if (busy || !lastScreen) { return; }
  const rect = screenshot.getBoundingClientRect();
  post({
    type: 'tapPoint',
    clickX: event.clientX - rect.left,
    clickY: event.clientY - rect.top,
    displayWidth: rect.width,
    displayHeight: rect.height,
  });
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
document.getElementById('live-btn-launch').addEventListener('click', () => {
  showActionError('');
  post({ type: 'launch', bundleId: bundleIdInput.value });
});
document.getElementById('live-btn-terminate').addEventListener('click', () => {
  showActionError('');
  post({ type: 'terminate' });
});
document.getElementById('live-btn-pick-ios').addEventListener('click', () => {
  post({ type: 'pickInstallFile', platform: 'ios' });
});
document.getElementById('live-btn-pick-android').addEventListener('click', () => {
  post({ type: 'pickInstallFile', platform: 'android' });
});
document.getElementById('live-btn-install').addEventListener('click', () => {
  showActionError('');
  const selected = currentDevices.find((d) => d.id === deviceSelect.value);
  const isAndroid = !!selected && selected.platform === 'android';
  const path = isAndroid ? androidPathInput.value : iosPathInput.value;
  post({ type: 'install', path: path });
});
for (const dir of ['up', 'down', 'left', 'right']) {
  document.getElementById('live-btn-swipe-' + dir).addEventListener('click', () => {
    showActionError('');
    post({ type: 'swipe', direction: dir });
  });
}
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
    case 'actionError':
      showActionError(message.message);
      break;
    case 'busy':
      setBusy(!!message.busy);
      break;
    case 'installPathPicked':
      if (message.platform === 'android') { androidPathInput.value = message.path; }
      else { iosPathInput.value = message.path; }
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
