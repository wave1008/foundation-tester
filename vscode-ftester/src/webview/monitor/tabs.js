// switchTabはcloseDeviceOpMenu(deviceTiles.js)・closeMachineDeviceMenu(machineProfilesTab.js)・
// applyTilePaneHeight/tilePaneHeight(splitter.js)のimportに依存する。

import { vscode } from './vscodeApi.js';
import { devicesPanel } from './domRefs.js';
import { closeDeviceOpMenu } from './deviceTiles.js';
import { closeMachineDeviceMenu } from './machineProfilesTab.js';
import { applyTilePaneHeight, tilePaneHeight } from './splitter.js';

export const TAB_IDS = ['devices', 'profiles', 'processes', 'settings'];
const tabButtons = {
  devices: document.getElementById('tab-devices'),
  profiles: document.getElementById('tab-profiles'),
  processes: document.getElementById('tab-processes'),
  settings: document.getElementById('tab-settings'),
};
const tabPanels = {
  devices: devicesPanel,
  profiles: document.getElementById('panel-profiles'),
  processes: document.getElementById('panel-processes'),
  settings: document.getElementById('panel-settings'),
};

function persistActiveTab(tab) {
  vscode.setState(Object.assign({}, vscode.getState(), { activeTab: tab }));
}

export function switchTab(tab) {
  // タブ切替中に前のタブで開いていた右クリックメニューを残さない。
  closeDeviceOpMenu();
  closeMachineDeviceMenu();
  for (const id of TAB_IDS) {
    const isActive = id === tab;
    tabButtons[id].classList.toggle('active', isActive);
    tabButtons[id].setAttribute('aria-selected', String(isActive));
    tabPanels[id].style.display = isActive ? 'flex' : 'none';
  }
  if (tab === 'devices') {
    // 非表示中はclientHeight=0のガードで何もしなかった分を再クランプする(splitter.js参照)。
    applyTilePaneHeight(tilePaneHeight);
  }
  // processesTab.js の初回活性化フック(常駐プロセス即時更新)が依存する。
  document.dispatchEvent(new CustomEvent('ft-tab-activated', { detail: { tab } }));
}

/** tab が未知のIDなら何もしない(host からの switchTab メッセージ・クリックハンドラ共通)。 */
export function activateTab(tab) {
  if (!TAB_IDS.includes(tab)) {
    return;
  }
  switchTab(tab);
  persistActiveTab(tab);
}

for (const id of TAB_IDS) {
  tabButtons[id].addEventListener('click', () => {
    if (tabButtons[id].classList.contains('active')) {
      return;
    }
    activateTab(id);
  });
}

// data-target先へスクロール。scroll-margin-top(.profile-section、CSS側)でsticky見出しの
// 裏に隠れないようにしてある。
for (const link of document.querySelectorAll('.profile-jump-link')) {
  link.addEventListener('click', () => {
    const target = document.getElementById(link.dataset.target);
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });
}
