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
  applyH264Chunk, applyStreamUnavailable,
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
import { applyHostMetrics, recordFmCalls, resetFmUsage, setHostMetricMachines } from './hostCharts.js';
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
  applyInstallCmdlineToolsResult,
  applyCreateDeviceResult,
  applyBatchCreateStarted,
  applyBatchCreateProgress,
  applyBatchCreateFinished,
  applyInstalledDevices,
  applyDevicePickDeviceDeleteResult,
  applyMachineDevicesSyncResult,
  applyNameInputOpen,
} from './modals.js';
import { applySettings } from './settingsTab.js';
import { applyDevicePickMachines } from './devicePickMachine.js';
import { applyResidentMessage } from './processesTab.js';
import { applyRecordingsSessions, applyRecordingsSession } from './recordingsTab.js';
import { activateTab, TAB_IDS, switchTab } from './tabs.js';
import { setTilePaneHeight, setTileAutoFit } from './splitter.js';
import { adoptTitleHoverTips } from './hoverTip.js';

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
    // 契約: { type:'streamUnavailable', device, unavailable }
    // (monitorDeviceStreamController.ts が配信を諦めたとき true)
    case 'streamUnavailable':
      applyStreamUnavailable(message);
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
    case 'hostMetricsMachines':
      // 行の集合(手元 + リモート機)。値より先に届くので、観測が来る前から行が見える
      setHostMetricMachines(message.machines);
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
      // FM 実測はシナリオ完了時にしか来ない(hostMetrics ストリームには乗らない)。
      // hostCharts 側が次の tick で系列へ積む
      if (message.action && message.action.type === 'fmUsage') {
        recordFmCalls(message.action.calls, message.action.totalMs, message.action.failures,
          message.action.machine);
      }
      if (message.action && message.action.type === 'cleared') {
        resetFmUsage();
      }
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
    case 'installCmdlineToolsResult':
      applyInstallCmdlineToolsResult(message);
      break;
    case 'createDeviceResult':
      applyCreateDeviceResult(message);
      break;
    case 'batchCreateStarted':
      applyBatchCreateStarted(message);
      break;
    case 'batchCreateProgress':
      applyBatchCreateProgress(message);
      break;
    case 'batchCreateFinished':
      applyBatchCreateFinished(message);
      break;
    case 'installedDevices':
      applyInstalledDevices(message);
      break;
    case 'devicePickDeviceDeleteResult':
      applyDevicePickDeviceDeleteResult(message);
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
    case 'keepPhysicalDevicesAwake':
    case 'lptScheduling':
    case 'lptHistoryRuns':
    case 'language':
    case 'updateStatus':
      applySettings(message);
      break;
    // devicePickMachine.js は remoteConfig(#device-pick-overlay 内のマシン選択の選択肢)を独立に
    // 購読する(settingsTab.js の hostRows とは別モジュールの別コピー)。この case が無いと
    // remoteConfig は default で握り潰され、設定タブのリモートホスト一覧も
    // 「既存から選択」ダイアログのホスト選択も初期化されない。
    case 'remoteConfig':
      applySettings(message);
      applyDevicePickMachines(message);
      break;
    case 'residentProcesses':
      applyResidentMessage(message);
      break;
    case 'recordingsSessions':
      applyRecordingsSessions(message);
      break;
    case 'recordingsSession':
      applyRecordingsSession(message);
      break;
    case 'tilePaneHeight':
      setTilePaneHeight(message.value);
      break;
    case 'tileAutoFit':
      setTileAutoFit(message.value);
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

// ツールバー右端のアイコンボタン(全選択・高さ自動調整)の説明は、ネイティブ title(約1秒・
// 遅延を指定できない)ではなくタイルと同じ自前ツールチップ(0.2秒)で出す。
// 全選択ボタンの文言は押すたびに変わるので deviceTiles.js が自分で setHoverTip する。
adoptTitleHoverTips('#toolbar .icon-button[title]');

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
