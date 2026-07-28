// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorModel.ts の setPollingMode/pollingMode・
// setLanguage/language メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。
//
// 更新セクション: checkUpdate/runUpdate を送り、updateStatus/updateLog/updateFinished を受ける
// (実処理は src/monitorUpdateController.ts → Scripts/update-check.sh / update.sh)。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');
const languageSelect = document.getElementById('settings-language');
const updateStatus = document.getElementById('settings-update-status');
const updateCheckButton = document.getElementById('settings-update-check');
const updateRunButton = document.getElementById('settings-update-run');
const updateLog = document.getElementById('settings-update-log');

pollingModeCheckbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setPollingMode', value: pollingModeCheckbox.checked });
});

// 表示言語の変更。拡張側が ftester.language 設定を更新し、完全反映には再読み込みが要る
// (案内は extension.ts が出す)。
languageSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'setLanguage', value: languageSelect.value });
});

updateCheckButton.addEventListener('click', () => {
  vscode.postMessage({ type: 'checkUpdate' });
});

// 確認ダイアログは**ホスト側**(monitorUpdateController.ts の showWarningMessage modal)。
// webview では window.confirm/alert が効かない(VSCode の制約。他タブの削除確認も同じ方式)。
updateRunButton.addEventListener('click', () => {
  vscode.postMessage({ type: 'runUpdate' });
});

function shortSha(value) {
  return typeof value === 'string' ? value.slice(0, 8) : '';
}

function applyUpdateStatus(message) {
  const running = message.state === 'running';
  // 実行中は両方止める(二重起動と、更新の最中に判定を走らせるのを防ぐ)。
  updateCheckButton.disabled = running || message.state === 'checking';
  updateRunButton.disabled = running || message.state === 'checking'
    || message.state === 'unavailable' || message.state === 'pinned';
  updateStatus.classList.remove('available', 'attention');

  switch (message.state) {
    case 'checking':
      updateStatus.textContent = t('wvMonitor2.update.checking');
      break;
    case 'running':
      updateStatus.textContent = t('wvMonitor2.update.running');
      break;
    case 'up-to-date':
      updateStatus.textContent = t('wvMonitor2.update.upToDate', { local: shortSha(message.localHead) });
      break;
    case 'update-available':
      updateStatus.textContent = t('wvMonitor2.update.available', {
        local: shortSha(message.localHead),
        remote: shortSha(message.remoteHead),
      });
      updateStatus.classList.add('available');
      break;
    case 'pinned':
      updateStatus.textContent = t('wvMonitor2.update.pinned', { reason: message.reason || '' });
      updateStatus.classList.add('attention');
      break;
    case 'unavailable':
      updateStatus.textContent = t('wvMonitor2.update.unavailable');
      updateStatus.classList.add('attention');
      break;
    default:
      updateStatus.textContent = t('wvMonitor2.update.unknown', { reason: message.reason || '' });
      updateStatus.classList.add('attention');
  }
}

function appendUpdateLog(line) {
  updateLog.style.display = 'block';
  updateLog.textContent += `${line}\n`;
  updateLog.scrollTop = updateLog.scrollHeight; // 末尾に追従(進行が見えるように)
}

export function applySettings(message) {
  if (message.type === 'pollingMode') {
    pollingModeCheckbox.checked = !!message.value;
  } else if (message.type === 'language') {
    languageSelect.value = message.value;
  } else if (message.type === 'updateLogReset') {
    updateLog.textContent = '';
    updateLog.style.display = 'block';
  } else if (message.type === 'updateStatus') {
    applyUpdateStatus(message);
  } else if (message.type === 'updateLog') {
    appendUpdateLog(message.line);
  } else if (message.type === 'updateFinished') {
    // 成功しても**このウィンドウを再読み込みするまで旧版が動き続ける**(拡張自身を入れ替えたため)。
    appendUpdateLog(message.exitCode === 0
      ? t('wvMonitor2.update.finishedOk')
      : t('wvMonitor2.update.finishedFailed', { code: String(message.exitCode) }));
  }
}
