// モニターパネル「FM探索」タブ(#panel-explore)。main.js が applyExploreMessage を message
// ディスパッチャに組み込む。host への送信は type:'explore' の封筒で包む(対向: src/exploreModel.ts の
// ExploreWebviewEnvelope、処理は src/monitorExploreController.ts)。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

function post(message) {
  vscode.postMessage({ type: 'explore', message });
}

const deviceSelect = document.getElementById('explore-device-select');
const banner = document.getElementById('explore-banner');
const bundleIdInput = document.getElementById('explore-bundle-id');
const goalInput = document.getElementById('explore-goal');
const maxStepsInput = document.getElementById('explore-max-steps');
const btnStart = document.getElementById('explore-btn-start');
const btnCancel = document.getElementById('explore-btn-cancel');
const runningLabel = document.getElementById('explore-running-label');
const formError = document.getElementById('explore-form-error');
const logEl = document.getElementById('explore-log');
const resultEl = document.getElementById('explore-result');
const btnOpenFile = document.getElementById('explore-btn-open-file');

const STATE_LABEL = {
  connected: t('wvMonitor2.explore.state.connected'),
  booted: t('wvMonitor2.explore.state.booted'),
  offline: t('wvMonitor2.explore.state.offline'),
  unknown: t('wvMonitor2.explore.state.unknown'),
};

const RESULT_SEVERITY_CLASS = {
  info: 'explore-result-info',
  warning: 'explore-result-warning',
  error: 'explore-result-error',
};

const formInputs = [bundleIdInput, goalInput, maxStepsInput];

let currentDevices = [];

// ---- デバイス選択 ---------------------------------------------------------------

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
}

deviceSelect.addEventListener('change', () => {
  post({ type: 'selectDevice', id: deviceSelect.value });
});
document.getElementById('explore-btn-refresh-devices').addEventListener('click', () => {
  post({ type: 'refreshDevices' });
});

// ---- バナー・フォームエラー ---------------------------------------------------------

function showBanner(text) {
  if (!text) { banner.classList.remove('visible'); banner.textContent = ''; return; }
  banner.textContent = text;
  banner.classList.add('visible');
}

function showFormError(text) {
  if (!text) { formError.classList.remove('visible'); formError.textContent = ''; return; }
  formError.textContent = text;
  formError.classList.add('visible');
}

// ---- 実行状態 --------------------------------------------------------------------

function setRunning(running) {
  btnStart.disabled = running;
  for (const input of formInputs) { input.disabled = running; }
  btnCancel.disabled = !running;
  runningLabel.textContent = running ? t('wvMonitor2.explore.running') : '';
}

// ---- 実行ログ --------------------------------------------------------------------

function appendLogLine(line) {
  const row = document.createElement('div');
  row.className = 'explore-log-line';
  row.textContent = line;
  logEl.appendChild(row);
  logEl.scrollTop = logEl.scrollHeight;
}

function replaceLogLines(lines) {
  logEl.innerHTML = '';
  for (const line of lines) { appendLogLine(line); }
}

// ---- 結果表示 --------------------------------------------------------------------

function applyResult(result) {
  if (!result) {
    resultEl.textContent = '';
    resultEl.className = 'explore-result';
    btnOpenFile.style.display = 'none';
    return;
  }
  resultEl.textContent = result.message;
  resultEl.className = 'explore-result ' + (RESULT_SEVERITY_CLASS[result.severity] || '');
  btnOpenFile.style.display = result.hasFile ? '' : 'none';
}

// ---- 操作ボタン ------------------------------------------------------------------

btnStart.addEventListener('click', () => {
  showFormError('');
  post({ type: 'start', bundleId: bundleIdInput.value, goal: goalInput.value, maxSteps: maxStepsInput.value });
});
btnCancel.addEventListener('click', () => {
  post({ type: 'cancel' });
});
btnOpenFile.addEventListener('click', () => {
  post({ type: 'openFile' });
});

// ---- host からのメッセージ(type:'explore' 封筒の中身。main.js のディスパッチャから呼ばれる) --------

export function applyExploreMessage(message) {
  switch (message.type) {
    case 'devices':
      applyDevices(message.devices, message.selectedId);
      break;
    case 'banner':
      showBanner(message.message);
      break;
    case 'formError':
      showFormError(message.message);
      break;
    case 'running':
      setRunning(!!message.running);
      break;
    case 'log':
      appendLogLine(message.line);
      break;
    case 'result':
      applyResult(message);
      break;
    case 'hydrate':
      applyDevices(message.devices, message.selectedId);
      setRunning(!!message.running);
      replaceLogLines(message.logLines);
      if (!bundleIdInput.value) { bundleIdInput.value = message.lastBundleId; }
      applyResult(message.result);
      break;
    default:
      break;
  }
}

// 初回タブ活性化時にデバイス一覧を自動取得する(liveTab.js と同じフック)。
let initialized = false;
document.addEventListener('ft-tab-activated', (event) => {
  if (event.detail.tab === 'explore' && !initialized) {
    initialized = true;
    post({ type: 'refreshDevices' });
  }
});
