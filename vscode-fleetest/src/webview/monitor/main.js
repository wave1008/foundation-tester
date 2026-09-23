// エントリポイント。機能別ESモジュール:
//   vscodeApi.js  acquireVsCodeApi(1回のみ)+persistedState / domRefs.js  共有DOM定数
//   splitter.js/deviceTiles.js/laneLog.js/hostCharts.js  「デバイスモニター」タブ
//   projectsTab.js/runProfileDevicesTab.js/appProfilesTab.js/runProfilesTab.js  プロファイルタブ
//   settingsTab.js  設定タブ / modals.js  3モーダル / tabs.js  タブ切替 / liveTab.js  「ライブ操作」タブ
// 各モジュールの import はトップレベルのイベント登録実行に必要(未使用に見えても消さない)。
// 外側IIFEは無い(esbuildのiife出力が同役割)。ここにはメッセージディスパッチャ・ツールバー
// ボタン・起動時ブートストラップのみを置く。

import { vscode, persistedState } from './vscodeApi.js';
import { btnUp, btnDown, btnRestart, btnRunTests } from './domRefs.js';
import {
  applyDevices,
  applyFrame,
  applyH264Chunk, applyStreamUnavailable, applyStreamStopped,
  applyDeviceError,
  showBanner,
  hideBanner,
  setBusy,
  noteUpCancelRequested,
  applyTestRunActive,
  applyRecordingsFinalizing,
  clearTilesForRestart,
  applyDeviceOpBusy,
  applyDeviceOpFailed,
  applyDeviceDownFinished,
  tiles,
  applyProfileInfo,
  applySelectAllDevices,
  applyPlatformFilter,
  applyBridgeWatch,
  applyHealthWatch,
  applyWipeStatus,
  applyDeviceAction,
} from './deviceTiles.js';
import { applyShowStreamDuringRun } from './streamToggle.js';
import { applyLaneAction, applyLaneHydrate, updateLaneVisibility } from './laneLog.js';
import { applyProjectInfo } from './projectsTab.js';
import { applyHostMetrics, setHostMetricMachines, setMachineLock } from './hostCharts.js';
import {
  applyMonitorRuns, resetRunBoard, setRunBoardCollapsed, setRunBoardExpandAll, setRunBoardMachines,
  refreshRunBoardDevices,
} from './runBoard.js';
import { applyProjectDeviceCatalog } from './runProfileDevicesTab.js';
import {
  applyAppProfileInfo,
  applyAppProfileSelected,
  applyAppProfileData,
  applyAppProfileSaveResult,
  applyAppProfileFileChanged,
} from './appProfilesTab.js';
import {
  applyRunProfileInfo,
  applyRunProfileSelected,
  applyRunProfileData,
  applyRunProfileSaveResult,
  applyRunProfileFileChanged,
} from './runProfilesTab.js';
import {
  applyDeviceCatalog,
  applyInstallCmdlineToolsResult,
  applyDeviceAddProgress,
  applyCreateDeviceResult,
  applyBatchCreateStarted,
  applyBatchCreateProgress,
  applyBatchCreateFinished,
  applyInstalledDevices,
  applyDevicePickDeviceDeleteResult,
  applyRunProfileDevicesSyncResult,
  applyNameInputOpen,
} from './modals.js';
import { applySettings } from './settingsTab.js';
import { applyDevicePickMachines } from './devicePickMachine.js';
import { applyMachineColors } from './machineColors.js';
import { applyResidentMessage } from './processesTab.js';
import { applyRecordingsSessions, applyRecordingsSession } from './recordingsTab.js';
import { activateTab, currentTab, HIDDEN_AT_STARTUP, TAB_IDS, switchTab } from './tabs.js';
import { applyLiveH264Chunk, applyLiveMessage, initLive, openLiveDevice, refreshLiveDevices, setLiveVisible } from './liveTab.js';
import { setTilePaneHeight, setFleetVisible, isFleetVisible, setLogPaneHeight, setRunBoardHeight, setLogViewVisible, setGridViewVisible } from './splitter.js';
import { adoptTitleHoverTips } from './hoverTip.js';
import { setDevicesWaiting } from './waitingNote.js';
import { handleDashboardMessage } from './dashboardTab.js';

const recordingsFinalizingNote = document.getElementById('run-recordings-finalizing');

window.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message.type !== 'string') {
    return;
  }
  switch (message.type) {
    case 'devices':
      // **バナーは消さない** —— 監視サイクルは約2秒ごとに来るので、ここで消すと
      // エラーが読む前に消える(実害 2026-08-29)。バナーはすべて失敗の通知なので、
      // 消えてよいのは利用者が閉じたとき・次のバナーで置き換わったとき・
      // 「モニター再起動」を押したときだけ(deviceTiles.js の showBanner)
      // **一覧は表示フィルタ前の全台**(絞り込みは deviceTiles.js の入口。
      // 契約: monitorWebviewMessages.ts の devicesToWebviewMessage)
      applyDevices(message.devices, message.filter);
      // run ボードのツリーは台の一覧から作る(runBoard.js)—— 呼ばないと古い台が残る
      refreshRunBoardDevices();
      break;
    case 'frame':
      applyFrame(message);
      break;
    case 'h264Chunk':
      applyH264Chunk(message);
      break;
    // 契約: { type:'streamStopped', device }(配信ヘルパーを落とした。次のフレームで canvas を降ろす)
    case 'streamStopped':
      applyStreamStopped(message);
      break;
    // 契約: { type:'streamUnavailable', device, unavailable }
    // (monitorDeviceStreamController.ts が配信を諦めたとき true)
    case 'streamUnavailable':
      applyStreamUnavailable(message);
      break;
    case 'deviceError':
      applyDeviceError(message);
      break;
    case 'testRunActive':
      applyTestRunActive(!!message.active);
      break;
    case 'recordingsFinalizing':
      recordingsFinalizingNote.hidden = !message.active;
      // 編集中は「テスト実行/テストを中断」を出さない(表示のたびに書く refreshRunTestsButton は display に触れない)
      btnRunTests.style.display = message.active ? 'none' : '';
      applyRecordingsFinalizing(!!message.active);
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
    case 'machineLock':
      // その機械の占有(錠前)。配信はホスト側で畳まれるので、ここは表示だけ
      setMachineLock(message.machine, message.held, message.issuer, message.mine);
      break;
    case 'hostMetricsMachines':
      // 行の集合(手元 + リモート機)。値より先に届くので、観測が来る前から行が見える
      setHostMetricMachines(message.machines);
      // run ボードのヘッダの機械要約も同じ集合を使う(専用のホスト配線を増やさない。runBoard.js 冒頭コメント参照)
      setRunBoardMachines(message.machines);
      break;
    case 'monitorRuns':
      applyMonitorRuns(message);
      break;
    case 'runBoardReset':
      resetRunBoard();
      break;
    case 'runBoardCollapsed':
      setRunBoardCollapsed(message.value);
      break;
    case 'runBoardExpandAll':
      setRunBoardExpandAll(message.value);
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
    case 'deviceAction':
      applyDeviceAction(message);
      break;
    case 'deviceOpFailed':
      // 先読みの印を捨ててから知らせる(捨てないと「起動中」表示のまま操作不能になる)
      applyDeviceOpFailed(message);
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
      applyProjectInfo(message);
      applyAppProfileInfo(message);
      // **カタログを先に更新する** —— applyRunProfileInfo が(未編集なら)再ロードを撃ち、
      // renderRunProfileEditor が devices 一覧を組み立てるときに最新のカタログを読む必要がある。
      applyProjectDeviceCatalog(message);
      applyRunProfileInfo(message);
      // run が無い機械の行は「何を見ている台か」にツールバーの選択を出す(runBoard.js)
      refreshRunBoardDevices();
      break;
    case 'deviceCatalog':
      applyDeviceCatalog(message);
      break;
    case 'installCmdlineToolsResult':
      applyInstallCmdlineToolsResult(message);
      break;
    case 'deviceAddProgress':
      applyDeviceAddProgress(message);
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
    case 'runProfileDevicesSyncResult':
      applyRunProfileDevicesSyncResult(message);
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
    case 'lptScheduling':
    case 'lptHistoryRuns':
    case 'remoteWaitLock':
    case 'language':
    case 'updateStatus':
    case 'retention':
      applySettings(message);
      break;
    // devicePickMachine.js は remoteConfig(#device-pick-overlay 内のマシン選択の選択肢)を独立に
    // 購読する(settingsTab.js の hostRows とは別モジュールの別コピー)。この case が無いと
    // remoteConfig は default で握り潰され、設定タブのリモートホスト一覧も
    // 「既存から選択」ダイアログのホスト選択も初期化されない。
    // **applyMachineColors を先に呼ぶ** —— settingsTab.js のスウォッチ描画(applySettings 内)が
    // machineColorPalette()/hexForColorKey() を読むため、パレットを先に更新しておく必要がある。
    case 'remoteHostRemoveConfirmed':
      applySettings(message);
      break;
    case 'remoteConfig':
      applyMachineColors(message);
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
      // reveal = run 完了時の自動表示(monitorRecordingsController.ts の revealRun)。「デバイスモニター」タブを
      // 見ているときだけ切り替える —— 他のタブで作業中なら奪わない(録画タブの再生中の別セッションも潰さない)。
      // 先に再生ビューへ差し替えてから切り替える: 逆順だと ft-tab-activated が一覧の再取得を撃つ
      if (message.reveal) {
        if (currentTab() === 'devices') {
          applyRecordingsSession(message);
          activateTab('recordings');
        }
        break;
      }
      applyRecordingsSession(message);
      break;
    case 'platformFilter':
      applyPlatformFilter(message);
      break;
    case 'runBoardHeight':
      setRunBoardHeight(message.value);
      break;
    case 'tilePaneHeight':
      setTilePaneHeight(message.value);
      break;
    case 'fleetVisible':
      setFleetVisible(message.value);
      break;
    case 'logPaneHeight':
      setLogPaneHeight(message.value);
      break;
    case 'logViewVisible':
      setLogViewVisible(message.value);
      break;
    case 'gridViewVisible':
      setGridViewVisible(message.value);
      break;
    case 'selectAllDevices':
      // ラインビューが非表示なら「すべて選択」から始める(タイルを押して選べないため)。
      // host は fleetVisible をこれより先に送る(monitorPanel.ts の ready)。保存値は書き換えない
      applySelectAllDevices(message.value || !isFleetVisible());
      break;
    case 'showStreamDuringRun':
      applyShowStreamDuringRun(message.value);
      break;
    case 'dashboard':
      handleDashboardMessage(message.message);
      break;
    case 'live':
      applyLiveMessage(message.message);
      break;
    case 'liveH264Chunk':
      applyLiveH264Chunk(message);
      break;
    case 'liveOpenDevice':
      activateTab('live');
      openLiveDevice(message.id);
      break;
    case 'liveRefreshDevicesFromHost':
      refreshLiveDevices();
      break;
    case 'panelVisible':
      monitorPanelVisible = !!message.visible;
      updateLiveVisible();
      break;
    default:
      break;
  }
});

// 「ライブ操作」タブの自動フレーム更新は、モニターの webview パネルが表示中(他エディタタブの
// 裏に隠れていない)かつ「ライブ操作」タブが選択中のときだけ回す(どちらか一方でも欠けると
// H.264 のエンコード/デコードが丸ごと無駄になる)。パネル生成直後は表示中という前提
// (createWebviewPanel 直後は visible。以後の切替は host からの panelVisible が更新する)。
let monitorPanelVisible = true;
function updateLiveVisible() {
  setLiveVisible(monitorPanelVisible && currentTab() === 'live');
}
document.addEventListener('ft-tab-activated', updateLiveVisible);

// bulk up 実行中フラグ(bootBusy で更新)。true の間、btnUp は「デバイスの起動を中断」として動く
// (ラベル切替は deviceTiles.js setBusy)。
let bulkUpActive = false;

btnUp.addEventListener('click', () => {
  if (bulkUpActive) {
    // 中断は bootBusy が返るまで数秒かかる。押されたことは webview 側で先に見せる
    // (受理の表示は deviceTiles.js の refreshBulkButtons)。
    noteUpCancelRequested();
    vscode.postMessage({ type: 'devicesUpCancel' });
    return;
  }
  // CPU 描画フォールバック中(CPUバッジ)の Android は restartNames として渡し、未起動機のブートと
  // 同一キュー(start-all-devices --restart。1ジョブ・2台ずつ並行)で down→up される。ジョブを分けないので
  // 種別を問わず常に最大2台だけが起動処理中(受信側: monitorPanel.ts → monitorDeviceOps.bulkUpWithRestarts)。
  // **手元の台だけ** —— `start-all-devices --restart` は手元の名簿で、リモートへ中継されない
  // (ApiDevicesUp)。リモートの CPU バッジ機の名前を混ぜると、手元の同名の台が再起動される
  const cpuNames = [...tiles.values()]
    .filter((entry) => entry.device.platform === 'android' && entry.device.renderMode === 'cpu'
      && !entry.device.machine)
    .map((entry) => entry.device.name);
  vscode.postMessage({ type: 'devicesUp', restartNames: cpuNames });
});
btnDown.addEventListener('click', () => vscode.postMessage({ type: 'devicesDown' }));
btnRestart.addEventListener('click', () => {
  hideBanner();
  // タイルと選択の掃除は deviceTiles.js が持つ(全選択の ON はそちらで据え置く)。
  clearTilesForRestart();
  vscode.postMessage({ type: 'restartMonitor' });
});

// ツールバー右端のアイコンボタン(全選択・高さ自動調整)の説明は、ネイティブ title(約1秒・
// 遅延を指定できない)ではなくタイルと同じ自前ツールチップ(0.2秒)で出す。
// 全選択ボタンの文言は押すたびに変わるので deviceTiles.js が自分で setHoverTip する。
adoptTitleHoverTips('#toolbar .icon-button[title]');

// 選択タブの永続化(vscode.getState())から復元する。不正値・未設定・起動時に出さないタブは 'devices'。
const initialTab =
  TAB_IDS.includes(persistedState.activeTab) && !HIDDEN_AT_STARTUP.includes(persistedState.activeTab)
    ? persistedState.activeTab
    : 'devices';
switchTab(initialTab);

// パネルのどこ(全タブ・モーダル)で右クリックしても既定メニュー(Cut/Copy/Paste)を出さない。
// 文字を打つ入力欄だけは残す(貼り付けが要る)。stopPropagation しない = 開いている自前メニューを閉じる
// 他の document の contextmenu リスナはそのまま届く。タイル・空きエリア・実行ログ等は各自で自前メニューを出す。
// 拡張の全画面で揃える規則(対: src/healReviewPanel.ts のインラインスクリプトの同じリスナ)
document.addEventListener('contextmenu', (event) => {
  const target = event.target;
  const editable = target instanceof HTMLTextAreaElement
    || (target instanceof HTMLInputElement && !['checkbox', 'radio', 'button', 'range'].includes(target.type))
    || (target instanceof HTMLElement && target.isContentEditable);
  if (!editable) {
    event.preventDefault();
  }
});
// switchTab が発火する 'ft-tab-activated' で updateLiveVisible() が呼ばれ、初期タブが 'live' の
// ときだけ visibility:true を送る(それ以外は false のまま。setLiveVisible 呼び出し順は initLive()
// の前後を問わない。可視性通知とデバイス一覧要求は互いに独立)。
initLive();

// 初回 monitorDevices が届くまで(monitor プロセス起動+初回スキャンで数秒かかる)、待機メッセージを
// 表示する。.empty は CSS 既定 display:none で、これが無いと最初のイベントまでタイル領域が無言の空白に
// なる(restartMonitor ハンドラと同じ既知・安全な出し方。applyDevices が実デバイス到着後に none へ戻す)。
setDevicesWaiting(true);

updateLaneVisibility();

// ready ハンドシェイク: 全リスナー登録済みをhostに通知。hostはこれを受けて初期状態を送る。
vscode.postMessage({ type: 'ready' });
