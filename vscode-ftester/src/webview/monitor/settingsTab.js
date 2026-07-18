// モニターパネル「設定」タブ(#panel-settings)。main.js が applySettings を message
// ディスパッチャに組み込む。対向: src/monitorModel.ts の setPollingMode/pollingMode
// メッセージ、処理は src/monitorPanel.ts。常駐プロセス一覧は processesTab.js を参照。

import { vscode } from './vscodeApi.js';

const pollingModeCheckbox = document.getElementById('settings-polling-mode');

pollingModeCheckbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setPollingMode', value: pollingModeCheckbox.checked });
});

export function applySettings(message) {
  if (message.type === 'pollingMode') {
    pollingModeCheckbox.checked = !!message.value;
  }
}
