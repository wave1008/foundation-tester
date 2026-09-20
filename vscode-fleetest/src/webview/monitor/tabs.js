// switchTabはcloseDeviceOpMenu(deviceTiles.js)・closeDeviceMenu(runProfileDevicesTab.js)・
// reapplyTilePaneHeight(splitter.js)のimportに依存する。

import { vscode } from './vscodeApi.js';
import { devicesPanel } from './domRefs.js';
import { closeDeviceOpMenu } from './deviceTiles.js';
import { closeDeviceMenu as closeRunProfileDeviceMenu } from './runProfileDevicesTab.js';
import { reapplyTilePaneHeight } from './splitter.js';

export const TAB_IDS = ['dashboard', 'devices', 'live', 'recordings', 'profiles', 'processes', 'settings'];
const tabButtons = {
  dashboard: document.getElementById('tab-dashboard'),
  devices: document.getElementById('tab-devices'),
  live: document.getElementById('tab-live'),
  profiles: document.getElementById('tab-profiles'),
  processes: document.getElementById('tab-processes'),
  recordings: document.getElementById('tab-recordings'),
  settings: document.getElementById('tab-settings'),
};
const tabPanels = {
  dashboard: document.getElementById('panel-dashboard'),
  devices: devicesPanel,
  live: document.getElementById('panel-live'),
  profiles: document.getElementById('panel-profiles'),
  processes: document.getElementById('panel-processes'),
  recordings: document.getElementById('panel-recordings'),
  settings: document.getElementById('panel-settings'),
};

// 起動時はタブボタンを出さないタブ。activateTab で開いたときに現れる(パネルを開き直すまで残る)。
export const HIDDEN_AT_STARTUP = ['live', 'processes'];

let currentTabId = null;

function persistActiveTab(tab) {
  vscode.setState(Object.assign({}, vscode.getState(), { activeTab: tab }));
}

/** 表示中のタブ ID(初回 switchTab 前は null)。 */
export function currentTab() {
  return currentTabId;
}

export function switchTab(tab) {
  currentTabId = tab;
  // タブ切替中に前のタブで開いていた右クリックメニューを残さない。
  closeDeviceOpMenu();
  closeRunProfileDeviceMenu();
  for (const id of TAB_IDS) {
    const isActive = id === tab;
    tabButtons[id].classList.toggle('active', isActive);
    tabButtons[id].setAttribute('aria-selected', String(isActive));
    tabPanels[id].style.display = isActive ? 'flex' : 'none';
  }
  if (tab === 'devices') {
    // 非表示中はclientHeight=0のガードで何もしなかった分を再クランプする(splitter.js参照)。
    reapplyTilePaneHeight();
  }
  // デバイスタイルが display:none の間は配信helperとデコードが無駄になるのでホストへ知らせる
  // (対向: src/monitorWebviewMessages.ts の devicesTabVisible / monitorPanel.ts)。
  vscode.postMessage({ type: 'devicesTabVisible', visible: tab === 'devices' });
  // processesTab.js の初回活性化フック(常駐プロセス即時更新)が依存する。
  document.dispatchEvent(new CustomEvent('ft-tab-activated', { detail: { tab } }));
}

/** tab が未知のIDなら何もしない(host からの switchTab メッセージ・クリックハンドラ共通)。 */
export function activateTab(tab) {
  if (!TAB_IDS.includes(tab)) {
    return;
  }
  tabButtons[tab].style.display = '';
  switchTab(tab);
  persistActiveTab(tab);
}

// 閉じられるタブ → 表示中に閉じたときの移り先。閉じたタブは activateTab で開くと再び現れる
// (開く口: processes は設定タブ「ツール」・live はコマンド/タイル右クリック/Run Test)。
const CLOSE_FALLBACK = { live: 'devices', processes: 'settings' };

export function hideTab(tab) {
  tabButtons[tab].style.display = 'none';
  if (currentTabId === tab) {
    activateTab(CLOSE_FALLBACK[tab]);
  }
}

// 閉じる × はタブボタンの内側なので、ボタンの click(タブを開く)へ伝えない。
for (const tab of Object.keys(CLOSE_FALLBACK)) {
  document.getElementById(`tab-${tab}-close`).addEventListener('click', (event) => {
    event.stopPropagation();
    hideTab(tab);
  });
}

for (const id of TAB_IDS) {
  tabButtons[id].addEventListener('click', () => {
    if (tabButtons[id].classList.contains('active')) {
      return;
    }
    activateTab(id);
  });
}

