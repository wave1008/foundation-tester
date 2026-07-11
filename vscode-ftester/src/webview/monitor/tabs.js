// switchTabはcloseDeviceOpMenu(deviceTiles.js)・closeMachineDeviceMenu(machineProfilesTab.js)・
// applyTilePaneHeight/tilePaneHeight(splitter.js)のimportに依存する。

import { vscode } from './vscodeApi.js';
import { devicesPanel } from './domRefs.js';
import { closeDeviceOpMenu } from './deviceTiles.js';
import { closeMachineDeviceMenu } from './machineProfilesTab.js';
import { applyTilePaneHeight, tilePaneHeight } from './splitter.js';

export const TAB_IDS = ['devices', 'profiles', 'settings'];
const tabButtons = {
  devices: document.getElementById('tab-devices'),
  profiles: document.getElementById('tab-profiles'),
  settings: document.getElementById('tab-settings'),
};
const tabPanels = {
  devices: devicesPanel,
  profiles: document.getElementById('panel-profiles'),
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
}

for (const id of TAB_IDS) {
  tabButtons[id].addEventListener('click', () => {
    if (tabButtons[id].classList.contains('active')) {
      return;
    }
    switchTab(id);
    persistActiveTab(id);
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
