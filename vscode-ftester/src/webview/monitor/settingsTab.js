// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorModel.ts の setPollingMode/pollingMode・
// setLanguage/language メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。

import { vscode } from './vscodeApi.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');
const languageSelect = document.getElementById('settings-language');

pollingModeCheckbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setPollingMode', value: pollingModeCheckbox.checked });
});

// 表示言語の変更。拡張側が ftester.language 設定を更新し、完全反映には再読み込みが要る
// (案内は extension.ts が出す)。
languageSelect.addEventListener('change', () => {
  vscode.postMessage({ type: 'setLanguage', value: languageSelect.value });
});

export function applySettings(message) {
  if (message.type === 'pollingMode') {
    pollingModeCheckbox.checked = !!message.value;
  } else if (message.type === 'language') {
    languageSelect.value = message.value;
  }
}
