// 「デバイスモニター」タブの「配信を表示する」チェックボックス。
// 対向: src/monitorWebviewMessages.ts の setShowStreamDuringRun / showStreamDuringRun(monitorPanel.ts が永続化)。
// 初期値 ON(HTML の checked)は monitorPanel.ts の既定と揃える(片方だけ変えない)。

import { vscode } from './vscodeApi.js';

const checkbox = document.getElementById('chk-show-stream-during-run');

checkbox.addEventListener('change', () => {
  vscode.postMessage({ type: 'setShowStreamDuringRun', value: checkbox.checked });
});

export function applyShowStreamDuringRun(value) {
  checkbox.checked = value !== false;
}
