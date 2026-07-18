// エントリポイント。機能別ESモジュール:
//   vscodeApi.js  acquireVsCodeApi(1回のみ)+persistedState / domRefs.js  共有DOM定数
//   splitter.js/deviceTiles.js/laneLog.js/hostCharts.js  デバイスタブ
//   machineProfilesTab.js/appProfilesTab.js/runProfilesTab.js  プロファイルタブ
//   settingsTab.js  設定タブ / modals.js  3モーダル / tabs.js  タブ切替
// ライブ操作は独立パネル(src/webview/live/main.js、UI本体は liveTab.js を共有)へ分離済み。
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
  applyDeviceOpBusy,
  applyDeviceDownFinished,
  tiles,
  selectedDeviceIds,
  applyProfileInfo,
  applyBridgeWatch,
  applyHealthWatch,
  applyWipeStatus,
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
import { applySettings } from './settingsTab.js';
import { applyResidentMessage } from './processesTab.js';
import { activateTab, TAB_IDS, switchTab } from './tabs.js';
import { setTilePaneHeight } from './splitter.js';

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
    case 'deviceError':
      applyDeviceError(message);
      break;
    case 'bootBusy':
      bulkUpActive = !!message.busy && message.bulkOp === 'up';
      setBusy(!!message.busy, message.bulkOp);
      break;
    case 'processDown':
      showBanner(message.message);
      break;
    case 'hostMetrics':
      applyHostMetrics(message);
      break;
    case 'deviceOpBusy':
      applyDeviceOpBusy(message);
      break;
    case 'deviceDownFinished':
      applyDeviceDownFinished(message);
      break;
    case 'bridgeWatch':
      applyBridgeWatch(message);
      break;
    case 'healthWatch':
      applyHealthWatch(message);
      break;
    case 'wipeStatus':
      applyWipeStatus(message);
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
    case 'switchTab':
      activateTab(message.tab);
      break;
    case 'pollingMode':
    case 'language':
      applySettings(message);
      break;
    case 'residentProcesses':
    case 'residentKillResult':
      applyResidentMessage(message);
      break;
    case 'tilePaneHeight':
      setTilePaneHeight(message.value);
      break;
    default:
      break;
  }
});

// bulk up 実行中フラグ(bootBusy で更新)。true の間、btnUp は「デバイスの起動を中断」として動く
// (ラベル切替は deviceTiles.js setBusy)。
let bulkUpActive = false;

btnUp.addEventListener('click', () => {
  if (bulkUpActive) {
    vscode.postMessage({ type: 'devicesUpCancel' });
    return;
  }
  // CPU 描画フォールバック中(CPUバッジ)の Android は restartNames として渡し、未起動機のブートと
  // 同一キュー(devices-up --restart。1ジョブ・2台ずつ並行)で down→up される。ジョブを分けないので
  // 種別を問わず常に最大2台だけが起動処理中(受信側: monitorPanel.ts → monitorDeviceOps.bulkUpWithRestarts)。
  const cpuNames = [...tiles.values()]
    .filter((entry) => entry.device.platform === 'android' && entry.device.renderMode === 'cpu')
    .map((entry) => entry.device.name);
  vscode.postMessage({ type: 'devicesUp', restartNames: cpuNames });
});
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

// 初回 monitorDevices が届くまで(monitor プロセス起動+初回スキャンで数秒かかる)、待機メッセージを
// 表示する。.empty は CSS 既定 display:none で、これが無いと最初のイベントまでタイル領域が無言の空白に
// なる(restartMonitor ハンドラと同じ既知・安全な出し方。applyDevices が実デバイス到着後に none へ戻す)。
emptyMessage.style.display = 'flex';

updateLaneVisibility();
updateLanesPlaceholder();

// ready ハンドシェイク: 全リスナー登録済みをhostに通知。hostはこれを受けて初期状態を送る。
vscode.postMessage({ type: 'ready' });
