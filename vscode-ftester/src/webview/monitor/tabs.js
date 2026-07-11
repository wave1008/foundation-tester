// tabs.js
// 「デバイス/プロファイル/設定」の3タブ切り替えを担う。Phase 3(main.js のモジュール分割)で
// main.js の「---- タブ切り替え(デバイス/プロファイル/設定) ----」節から抽出した。
// 「設定」タブは現状プレースホルダーのみ(将来の機能追加先)。closeDeviceOpMenu(deviceTiles.js)・
// closeMachineDeviceMenu(machineProfilesTab.js)・applyTilePaneHeight/tilePaneHeight
// (splitter.js)のいずれも import 済みであることに依存する。

import { vscode } from './vscodeApi.js';
import { devicesPanel } from './domRefs.js';
import { closeDeviceOpMenu } from './deviceTiles.js';
import { closeMachineDeviceMenu } from './machineProfilesTab.js';
import { applyTilePaneHeight, tilePaneHeight } from './splitter.js';

// ---- タブ切り替え(デバイス/プロファイル/設定) -----------------------------

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
    // 非表示だった間 devicesPanel.clientHeight が 0 になり、applyTilePaneHeight が
    // ガードで何もせず抜けていた(誤クランプ防止)。再表示直後に呼び直して再クランプ+
    // relayoutTiles() する(applyTilePaneHeight が内部で relayoutTiles() まで行う)。
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

// プロファイルタブ先頭の sticky ジャンプヘッダー(#profile-jump-header)から各セクションへ
// スクロールする(data-target=セクションの id)。scroll-margin-top(.profile-section)で
// sticky ヘッダーの裏に見出しが隠れないようにしてある。
for (const link of document.querySelectorAll('.profile-jump-link')) {
  link.addEventListener('click', () => {
    const target = document.getElementById(link.dataset.target);
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });
}
