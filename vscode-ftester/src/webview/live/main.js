// main.js
// ライブ操作パネル webview のロジック。esbuild が media/live/main.js に iife 形式で
// バンドルし、renderHtml() が <script src="..."> で読み込む。

  (function () {
const vscode = acquireVsCodeApi();

const deviceSelect = document.getElementById('device-select');
const deviceWarning = document.getElementById('device-warning');
const busyLabel = document.getElementById('busy-label');
const banner = document.getElementById('banner');

const screenshotWrap = document.getElementById('screenshot-wrap');
const screenshot = document.getElementById('screenshot');
const hoverBox = document.getElementById('hover-box');
const screenshotPlaceholder = document.getElementById('screenshot-placeholder');

const bundleIdInput = document.getElementById('bundle-id');
const iosPathInput = document.getElementById('ios-path');
const androidPathInput = document.getElementById('android-path');
const installHint = document.getElementById('install-hint');
const typeTextInput = document.getElementById('type-text');
const typeRefHint = document.getElementById('type-ref-hint');
const actionError = document.getElementById('action-error');
const elementsList = document.getElementById('elements-list');

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
  'btn-refresh-devices', 'btn-launch', 'btn-terminate', 'btn-pick-ios', 'btn-pick-android',
  'btn-install', 'btn-refresh-snapshot', 'btn-swipe-up', 'btn-swipe-down', 'btn-swipe-left',
  'btn-swipe-right', 'btn-type',
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
  vscode.postMessage({ type: 'selectDevice', id: deviceSelect.value });
});

// ---- スクリーンショット(クリック=タップ、要素ホバー=枠オーバーレイ) -----------------

// liveModel.ts の frameToDisplayRect と同じ計算(webview は CSP により import 不可のため複製)。
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
  vscode.postMessage({
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
      vscode.postMessage({ type: 'tapRef', ref: element.ref });
    });
    row.addEventListener('mouseenter', () => showHover(element));
    row.addEventListener('mouseleave', hideHover);
    elementsList.appendChild(row);
  }
}

// ---- 操作ボタン ------------------------------------------------------------------

document.getElementById('btn-refresh-devices').addEventListener('click', () => {
  vscode.postMessage({ type: 'refreshDevices' });
});
document.getElementById('btn-refresh-snapshot').addEventListener('click', () => {
  showActionError('');
  vscode.postMessage({ type: 'refreshSnapshot' });
});
document.getElementById('btn-launch').addEventListener('click', () => {
  showActionError('');
  vscode.postMessage({ type: 'launch', bundleId: bundleIdInput.value });
});
document.getElementById('btn-terminate').addEventListener('click', () => {
  showActionError('');
  vscode.postMessage({ type: 'terminate' });
});
document.getElementById('btn-pick-ios').addEventListener('click', () => {
  vscode.postMessage({ type: 'pickInstallFile', platform: 'ios' });
});
document.getElementById('btn-pick-android').addEventListener('click', () => {
  vscode.postMessage({ type: 'pickInstallFile', platform: 'android' });
});
document.getElementById('btn-install').addEventListener('click', () => {
  showActionError('');
  const selected = currentDevices.find((d) => d.id === deviceSelect.value);
  const isAndroid = !!selected && selected.platform === 'android';
  const path = isAndroid ? androidPathInput.value : iosPathInput.value;
  vscode.postMessage({ type: 'install', path: path });
});
for (const dir of ['up', 'down', 'left', 'right']) {
  document.getElementById('btn-swipe-' + dir).addEventListener('click', () => {
    showActionError('');
    vscode.postMessage({ type: 'swipe', direction: dir });
  });
}
document.getElementById('btn-type').addEventListener('click', () => {
  showActionError('');
  vscode.postMessage({ type: 'typeText', text: typeTextInput.value, ref: selectedRef });
});

// ---- メッセージ受信 ---------------------------------------------------------------

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') { return; }
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
});
  })();
