// 「デバイスモニター」タブの「ライブ更新」トグル(見た目は style.css の .toggle-switch。
// 実体は checkbox なのでキーボード操作と change イベントはそのまま)。
// 対向: src/monitorWebviewMessages.ts の setShowStreamDuringRun / showStreamDuringRun(monitorPanel.ts が永続化)。
// 初期値 ON(HTML の checked)は monitorPanel.ts の既定と揃える(片方だけ変えない)。

import { vscode } from './vscodeApi.js';

const checkbox = document.getElementById('chk-show-stream-during-run');

// 見出し行(#grid-view-header)の中に居るので、クリックが親へ波及すると見出しの開閉トグルを
// 誤発火する(splitter.js)。ラベル全体(チェックボックス込み)で止める。
checkbox.closest('.run-stream-toggle').addEventListener('click', (event) => event.stopPropagation());

// OFF の間はホストが全台の配信と画面の取り込みを止める(monitorPanel.ts の applyDeviceStreamVisibility)ので、
// タイル(と拡大表示)は最後の絵のまま明度を下げる(style.css の .stream-display-off)
const devicesPanel = document.getElementById('panel-devices');

function applyDim() {
  devicesPanel.classList.toggle('stream-display-off', !checkbox.checked);
}

checkbox.addEventListener('change', () => {
  applyDim();
  vscode.postMessage({ type: 'setShowStreamDuringRun', value: checkbox.checked });
});

export function applyShowStreamDuringRun(value) {
  checkbox.checked = value !== false;
  applyDim();
}
