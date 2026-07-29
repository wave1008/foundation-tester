// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorWebviewMessages.ts の setPollingMode/pollingMode・
// setLanguage/language メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。
//
// 更新セクション: checkUpdate/runUpdate を送り、updateStatus を受ける(実処理は
// src/monitorUpdateController.ts → Scripts/update-check.sh / update.sh)。
// **実行ログはここには出さない** — VSCode の OUTPUT(ftester チャンネル)へ出す。

import { vscode } from './vscodeApi.js';
import { t } from '../i18n.js';
import { switchTab } from './tabs.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');
const languageSelect = document.getElementById('settings-language');
const updateStatus = document.getElementById('settings-update-status');
const updateSpinner = document.getElementById('settings-update-spinner');
const updateCheckButton = document.getElementById('settings-update-check');
// 「更新する」は設定タブの中ではなく**タブバー(設定タブの右隣)**にある(どのタブを見ていても目に入る)。
// 更新があるときだけ表示する — 押せない状態のボタンを常時見せても情報にならないため。
const updateRunButton = document.getElementById('tabbar-update');

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
  // 進行は OUTPUT パネル(ホスト側が前面に出す)と、この状態行のスピナーで見せる。
  // どのタブから押しても状態が見えるよう設定タブへ移動する。
  switchTab('settings');
  vscode.postMessage({ type: 'runUpdate' });
});

// 実行中はラベルを差し替えるので、初期ラベル(拡張側 t() で描画済み)を控えておく。
const updateRunLabel = updateRunButton.textContent;

function shortSha(value) {
  return typeof value === 'string' ? value.slice(0, 8) : '';
}

function applyUpdateStatus(message) {
  const running = message.state === 'running';
  // 実行中は確認を止める(更新の最中に判定を走らせない)。
  updateCheckButton.disabled = running || message.state === 'checking';
  // 「更新する」は**更新があるときだけ**出す。実行中は押せない状態で残す(消すと進行が分からない)。
  updateRunButton.style.display = message.state === 'update-available' || running ? 'block' : 'none';
  updateRunButton.disabled = running;
  updateRunButton.classList.toggle('busy', running);
  updateRunButton.textContent = running ? t('wvMonitor2.update.runningButton') : updateRunLabel;
  // 待たされる2状態(確認中・更新中)だけスピナーを回す。
  updateSpinner.style.display = running || message.state === 'checking' ? 'block' : 'none';
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

export function applySettings(message) {
  if (message.type === 'pollingMode') {
    pollingModeCheckbox.checked = !!message.value;
  } else if (message.type === 'language') {
    languageSelect.value = message.value;
  } else if (message.type === 'updateStatus') {
    applyUpdateStatus(message);
  }
}
