// main.js
// デバイスモニター webview のエントリポイント。機能別 ES モジュールへ分割されている:
//   vscodeApi.js        acquireVsCodeApi()(1回のみ呼べる)と起動時の persistedState
//   domRefs.js          ツールバー・タイル/出力ペイン・レーン等、複数モジュールが参照する DOM 定数
//   splitter.js         タイルペイン/出力ペインの上下スプリッター
//   deviceTiles.js      デバイスタイルの生成・描画・右クリックメニュー・選択・実行プロファイル選択
//   laneLog.js          出力ペインのログレーン
//   hostCharts.js       ツールバーのミニグラフ(CPU/GPU/ANE/メモリ)
//   machineProfilesTab.js  プロファイルタブ: マシンプロファイル一覧・デバイス編集・行メニュー
//   appProfilesTab.js   プロファイルタブ: アプリプロファイルの設定フォーム
//   runProfilesTab.js   プロファイルタブ: 実行プロファイルの設定フォーム
//   modals.js           デバイス追加/名前入力/既存デバイスから選択 の3モーダル
//   tabs.js             デバイス/プロファイル/設定タブの切り替え
// このファイル自体はエントリポイントとして、各モジュールの import(モジュール本体の
// トップレベル文=イベント登録がその場で実行される)と、複数モジュールにまたがる
// 「メッセージ受信ディスパッチャ」「ツールバーの起動/停止/再起動ボタン」「起動時の
// ブートストラップ呼び出し」だけを置く。手書きの外側 IIFE ラッパーは無い(esbuild の iife
// 形式バンドル出力が同じ役割を果たすため)。

import { vscode, persistedState } from './vscodeApi.js';
import { btnUp, btnDown, btnRestart, emptyMessage } from './domRefs.js';
import {
  applyDevices,
  applyFrame,
  applyDeviceError,
  showBanner,
  hideBanner,
  setBusy,
  closeDeviceOpMenu,
  findTileByName,
  renderOpBadge,
  renderDeviceOpMenuItem,
  deviceOpMenuEntry,
  tiles,
  selectedDeviceIds,
  applyProfileInfo,
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
import { TAB_IDS, switchTab } from './tabs.js';

// ---- メッセージ受信 ---------------------------------------------------------

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
        renderOpBadge(entry);
        if (deviceOpMenuEntry === entry) {
          renderDeviceOpMenuItem();
        }
      }
      break;
    }
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

// 初期化完了(全リスナー登録済み)を拡張側へ通知する(ready ハンドシェイク)。
// 拡張側はこれを受けて初期状態(laneHydrate/profileInfo等)を送る。
vscode.postMessage({ type: 'ready' });
