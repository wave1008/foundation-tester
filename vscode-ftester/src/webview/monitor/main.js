// エントリポイント。機能別ESモジュール:
//   vscodeApi.js  acquireVsCodeApi(1回のみ)+persistedState / domRefs.js  共有DOM定数
//   splitter.js/deviceTiles.js/laneLog.js/hostCharts.js  デバイスタブ
//   machineProfilesTab.js/appProfilesTab.js/runProfilesTab.js  プロファイルタブ
//   liveTab.js  ライブ操作タブ / exploreTab.js  FM探索タブ / settingsTab.js  設定タブ
//   modals.js  3モーダル / tabs.js  タブ切替
// 各モジュールの import はトップレベルのイベント登録実行に必要(未使用に見えても消さない)。
// 外側IIFEは無い(esbuildのiife出力が同役割)。ここにはメッセージディスパッチャ・ツールバー
// ボタン・起動時ブートストラップのみを置く。

import { vscode, persistedState } from './vscodeApi.js';
import { btnUp, btnDown, btnRestart, emptyMessage } from './domRefs.js';
import {
  applyDevices,
  applyFrame,
  applyH264Chunk,
  applyDeviceError,
  showBanner,
  hideBanner,
  setBusy,
  closeDeviceOpMenu,
  findTileByName,
  renderMeta,
  tiles,
  selectedDeviceIds,
  applyProfileInfo,
  applyBridgeWatch,
} from './deviceTiles.js';
import { applyLaneAction, applyLaneHydrate, updateLaneVisibility, updateLanesPlaceholder } from './laneLog.js';
import { applyHostMetrics } from './hostCharts.js';
import {
  applyMachineProfileInfo,
  applyMachineProfileSelected,
  applyMachineDeviceUpdateResult,
} from './machineProfilesTab.js';
import {
  applyAppProfileInfo,
  applyAppProfileSelected,
  applyAppProfileData,
  applyAppProfileSaveResult,
  applyAppProfileFileChanged,
} from './appProfilesTab.js';
import {
  applyRunProfileInfo,
  rerenderRunProfileFormIfClean,
  applyRunProfileSelected,
  applyRunProfileData,
  applyRunProfileSaveResult,
  applyRunProfileFileChanged,
} from './runProfilesTab.js';
import {
  applyDeviceCatalog,
  applyCreateDeviceResult,
  applyInstalledDevices,
  applyMachineDevicesSyncResult,
  applyNameInputOpen,
} from './modals.js';
import { applyLiveMessage, applyLiveH264Chunk } from './liveTab.js';
import { applyExploreMessage } from './exploreTab.js';
import { applySettings } from './settingsTab.js';
import { activateTab, TAB_IDS, switchTab } from './tabs.js';

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') {
    return;
  }
  switch (message.type) {
    case 'devices':
      hideBanner();
      applyDevices(message.devices);
      break;
    case 'frame':
      applyFrame(message);
      break;
    case 'h264Chunk':
      applyH264Chunk(message);
      break;
    case 'liveH264Chunk':
      applyLiveH264Chunk(message);
      break;
    case 'deviceError':
      applyDeviceError(message);
      break;
    case 'bootBusy':
      setBusy(!!message.busy);
      break;
    case 'processDown':
      showBanner(message.message);
      break;
    case 'hostMetrics':
      applyHostMetrics(message);
      break;
    case 'deviceOpBusy': {
      const entry = findTileByName(message.name);
      if (entry) {
        entry.opBusy = message.op ? { op: message.op, status: message.status || 'running' } : undefined;
        // opBusy の有無は footer の bridgeWatch 優先度判定にも影響するため renderMeta で一括再描画する
        // (renderOpBadge/デバイス操作メニュー項目の再描画も内部で行う)。
        renderMeta(entry);
      }
      break;
    }
    case 'bridgeWatch':
      applyBridgeWatch(message);
      break;
    case 'deviceOpFailed':
      showBanner(message.name + ': ' + message.message);
      break;
    case 'laneSectionVisible':
      // レーンは常時表示のため何もしない(TS側からのメッセージ自体は互換のため残る)
      break;
    case 'runEvent':
      applyLaneAction(message.action);
      break;
    case 'laneHydrate':
      applyLaneHydrate(message.snapshot);
      break;
    case 'profileInfo':
      applyProfileInfo(message);
      applyAppProfileInfo(message);
      applyRunProfileInfo(message);
      break;
    case 'machineProfileInfo':
      applyMachineProfileInfo(message);
      rerenderRunProfileFormIfClean();
      break;
    case 'machineProfileSelected':
      applyMachineProfileSelected(message);
      break;
    case 'deviceCatalog':
      applyDeviceCatalog(message);
      break;
    case 'createDeviceResult':
      applyCreateDeviceResult(message);
      break;
    case 'installedDevices':
      applyInstalledDevices(message);
      break;
    case 'machineDevicesSyncResult':
      applyMachineDevicesSyncResult(message);
      break;
    case 'machineDeviceUpdateResult':
      applyMachineDeviceUpdateResult(message);
      break;
    case 'runProfileSelected':
      applyRunProfileSelected(message);
      break;
    case 'runProfileData':
      applyRunProfileData(message);
      break;
    case 'runProfileSaveResult':
      applyRunProfileSaveResult(message);
      break;
    case 'runProfileFileChanged':
      applyRunProfileFileChanged(message);
      break;
    case 'appProfileSelected':
      applyAppProfileSelected(message);
      break;
    case 'appProfileData':
      applyAppProfileData(message);
      break;
    case 'appProfileSaveResult':
      applyAppProfileSaveResult(message);
      break;
    case 'appProfileFileChanged':
      applyAppProfileFileChanged(message);
      break;
    case 'nameInputOpen':
      applyNameInputOpen(message);
      break;
    case 'live':
      applyLiveMessage(message.message);
      break;
    case 'explore':
      applyExploreMessage(message.message);
      break;
    case 'switchTab':
      activateTab(message.tab);
      break;
    case 'pollingMode':
      applySettings(message);
      break;
    default:
      break;
  }
});

btnUp.addEventListener('click', () => vscode.postMessage({ type: 'devicesUp' }));
btnDown.addEventListener('click', () => vscode.postMessage({ type: 'devicesDown' }));
btnRestart.addEventListener('click', () => {
  hideBanner();
  closeDeviceOpMenu();
  for (const entry of tiles.values()) {
    entry.tile.remove();
  }
  tiles.clear();
  selectedDeviceIds.clear();
  emptyMessage.style.display = 'flex';
  vscode.postMessage({ type: 'restartMonitor' });
});

// 選択タブの永続化(vscode.getState())から復元する。不正値・未設定は 'devices'。
const initialTab = TAB_IDS.includes(persistedState.activeTab) ? persistedState.activeTab : 'devices';
switchTab(initialTab);

updateLaneVisibility();
updateLanesPlaceholder();

// ready ハンドシェイク: 全リスナー登録済みをhostに通知。hostはこれを受けて初期状態を送る。
vscode.postMessage({ type: 'ready' });
