// lanesの読み書きはこのモジュールに閉じる。deviceTiles.jsとはselectedDeviceIds/tiles/
// runningWorkers(いずれも再代入されないMap/Set)を介して相互参照する。

import { MAX_LANE_LINES, OVERALL_LANE_ID, overallLaneName } from "../../runLaneModel";
import { lanesTitle, lanesPlaceholder, lanesGrid, lanesSelectionStatus, lanesRunStatus } from './domRefs.js';
import { tiles, selectedDeviceIds, attachDeviceMirror, detachDeviceMirror } from './deviceTiles.js';
import { t } from '../i18n.js';
import { setHoverTip } from './hoverTip.js';
import { computePreviewGrid } from './previewGridModel.js';

// レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
const lanes = new Map();

// devices同期(タイルと同じ配列)のid順。レーンの列順は常にこれに合わせる。
// lanesConfigured(workersReady)はワーカー合流順(Android先行・iOS後合流)で届くため、
// DOM追加順のままだとタイルの並びと食い違う。
let deviceOrder = [];

// lanesGridの子要素をdeviceOrder順に並べ直す(appendChildは既存ノードの移動)。
// deviceOrderに無いid(全体レーン等)は末尾・相対順維持。
// 動かすのは pairEl(拡大表示+ログの組)。lanesGrid の直接の子は常に .lane-pair。
function reorderLanes() {
  if (deviceOrder.length === 0) {
    return;
  }
  const rank = new Map(deviceOrder.map((id, index) => [id, index]));
  const ordered = [...lanes.keys()].sort(
    (a, b) => (rank.get(a) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b) ?? Number.MAX_SAFE_INTEGER),
  );
  for (const id of ordered) {
    lanesGrid.appendChild(lanes.get(id).pairEl);
  }
}

// worker id(またはタイルが存在しない全体レーン)ごとの「実行中」状態。
export const runningWorkers = new Set();

function setTileRunning(id, running) {
  if (running) {
    runningWorkers.add(id);
  } else {
    runningWorkers.delete(id);
  }
  const entry = tiles.get(id);
  if (entry) {
    entry.runningBadgeEl.style.display = running ? 'inline-block' : 'none';
  }
}

// platform不明(全体レーンやフォールバック)は中立色のピル。
// machineHost は複数の機械にまたがる実行でのみ付く。同名のデバイスが別の機械にも居るので、
// これを出さないと見出しが同じレーンが並んで区別できない(タイルの .badge-remote と同じ見た目)。
function setLaneHeader(headerEl, name, platform, machineHost) {
  headerEl.textContent = '';
  const pill = document.createElement('span');
  pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
  pill.textContent = name;
  setHoverTip(pill, machineHost ? machineHost + ' / ' + name : name);
  headerEl.appendChild(pill);
  if (machineHost) {
    const host = document.createElement('span');
    host.className = 'badge badge-remote lane-host';
    host.textContent = machineHost;
    headerEl.appendChild(host);
  }
}

// updateLabel=trueはdevices同期等のレーン構成時のみ。appendLaneLineから呼ぶ時にtrueにすると、
// フォールバック名(生のworker id)で構成済み表示名を上書きしてしまう。
function ensureLane(id, name, platform, updateLabel, machineHost) {
  let lane = lanes.get(id);
  if (lane) {
    if (updateLabel) {
      setLaneHeader(lane.headerEl, name, platform, machineHost);
    }
    return lane;
  }
  const el = document.createElement('div');
  el.className = 'lane';
  const header = document.createElement('div');
  header.className = 'lane-header';
  setLaneHeader(header, name, platform, machineHost);
  const body = document.createElement('div');
  body.className = 'lane-body';
  el.append(header, body);
  // 拡大表示はログの左。中身(タイルの絵の複製)は deviceTiles.js が入れる。デバイスを選択して
  // いない間は display:none で、レーンは従来どおりログだけになる(updateLaneVisibility)。
  const pair = document.createElement('div');
  pair.className = 'lane-pair';
  const preview = document.createElement('div');
  preview.className = 'lane-preview';
  preview.style.display = 'none';
  pair.append(preview, el);
  lanesGrid.appendChild(pair);

  lane = { el, pairEl: pair, previewEl: preview, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
  body.addEventListener('scroll', () => {
    lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
  });
  lanes.set(id, lane);
  updateLaneVisibility();
  return lane;
}

// レーンを畳むときは拡大表示の登録も外す(残すと deviceTiles.js が DOM から外れた要素へ
// 描き続ける)。lanes からの delete は呼び手が行う(反復中の削除を呼び手側で制御するため)。
function removeLane(id, lane) {
  detachDeviceMirror(id);
  lane.pairEl.remove();
}

function appendLaneLine(laneId, text) {
  const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? overallLaneName() : laneId, undefined, false);
  const wasAtBottom = lane.atBottom;
  const line = document.createElement('div');
  line.className = 'lane-line';
  line.textContent = text;
  lane.bodyEl.appendChild(line);
  lane.lineCount += 1;
  while (lane.lineCount > MAX_LANE_LINES) {
    const first = lane.bodyEl.firstChild;
    if (!first) {
      break;
    }
    lane.bodyEl.removeChild(first);
    lane.lineCount -= 1;
  }
  if (wasAtBottom) {
    lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
  }
}

function clearAllLanes() {
  for (const [id, lane] of lanes) {
    removeLane(id, lane);
  }
  lanes.clear();
  for (const id of [...runningWorkers]) {
    setTileRunning(id, false);
  }
  lanesRunStatus.textContent = '';
  updateLaneVisibility();
}

function configureLanes(laneInfos) {
  const nextIds = new Set(laneInfos.map((l) => l.id));
  for (const [id, lane] of [...lanes]) {
    if (!nextIds.has(id)) {
      removeLane(id, lane);
      lanes.delete(id);
    }
  }
  for (const info of laneInfos) {
    ensureLane(info.id, info.name, info.platform, true, info.machineHost);
  }
  reorderLanes();
  updateLaneVisibility();
}

export function updateLaneVisibility() {
  const allIds = [...lanes.keys()];
  const activeIds = selectedDeviceIds.size > 0
    ? allIds.filter((id) => selectedDeviceIds.has(id))
    : allIds;
  // デバイスを選択している間は拡大表示だけを並べる(ログは置かない。ユーザー決定 2026-08-24)。
  // 絞り込み無し(選択なし)は従来どおり全レーンのログ。
  const previewEnabled = selectedDeviceIds.size > 0;
  const previewIds = [];
  for (const [id, lane] of lanes) {
    const visible = activeIds.includes(id);
    lane.pairEl.style.display = visible ? 'flex' : 'none';
    // 全体レーン(__overall__)にはタイルが無いので拡大表示も無い(ログのまま出す)。
    const showPreview = previewEnabled && visible && tiles.has(id);
    lane.previewEl.style.display = showPreview ? 'flex' : 'none';
    lane.el.style.display = showPreview ? 'none' : 'flex';
    if (showPreview) {
      attachDeviceMirror(id, lane.previewEl);
      previewIds.push(id);
    } else {
      detachDeviceMirror(id);
    }
  }
  relayoutLanesGrid(activeIds.length, previewIds);
  // 見出しは中身に合わせる(選択中はログではなく拡大した動画を並べているため)。
  lanesTitle.textContent = previewEnabled
    ? t('wvMonitor2.laneLog.titleDevices')
    : t('wvMonitor2.laneLog.titleRunLog');
  lanesSelectionStatus.textContent = selectedDeviceIds.size > 0
    ? t('wvMonitor2.laneLog.selectedCount', { count: selectedDeviceIds.size })
    : t('wvMonitor2.laneLog.allWorkers');
}

// 直近の段組み計算に使った引数(ResizeObserver / アスペクト確定からの再計算で使い回す)。
let previewLayoutIds = [];
let previewLaneCount = 1;

// ログだけのときは従来どおり横一列。拡大表示のときは「絵が一番大きくなる」段組みにする
// (計算は previewGridModel.js。行も列も 1fr の等分なので、あとは grid-template を書くだけ)。
function relayoutLanesGrid(laneCount, previewIds) {
  previewLaneCount = laneCount;
  previewLayoutIds = previewIds;
  const previewing = previewIds.length > 0;
  lanesGrid.classList.toggle('previewing', previewing);
  if (!previewing) {
    lanesGrid.style.gridTemplateColumns = 'repeat(' + Math.max(1, laneCount) + ', minmax(0, 1fr))';
    lanesGrid.style.gridTemplateRows = '';
    return;
  }
  // 一番横に広い台に合わせる(狭い台はその枠の中で letterbox される)。
  let aspect = 0;
  for (const id of previewIds) {
    const value = parseFloat(tiles.get(id)?.tileAspect);
    if (value > aspect) {
      aspect = value;
    }
  }
  const gridStyle = getComputedStyle(lanesGrid);
  const grid = computePreviewGrid({
    // classList の変更後に読むこと(拡大表示中はスクロールバーを出さないぶん幅が広い)
    paneWidth: lanesGrid.clientWidth,
    paneHeight: lanesGrid.clientHeight,
    count: previewIds.length,
    aspect,
    gap: parseFloat(gridStyle.rowGap),
    chromeHeight: measurePreviewChromeHeight(),
  });
  lanesGrid.style.gridTemplateColumns = 'repeat(' + grid.columns + ', minmax(0, 1fr))';
  lanesGrid.style.gridTemplateRows = 'repeat(' + grid.rows + ', minmax(0, 1fr))';
}

// 1セルのうち絵以外(タグ段 + その下の間隔)の高さ。定数を置かず実測する(style.css を
// 変えたときに片方だけ古くなるのを防ぐ)。レイアウト未確定なら 0。
function measurePreviewChromeHeight() {
  const preview = lanesGrid.querySelector('.lane-preview');
  const frame = preview && preview.querySelector('.lane-preview-frame');
  if (!preview || !frame) {
    return 0;
  }
  return Math.max(0, preview.clientHeight - frame.clientHeight);
}

// ペインの大きさが変わったら組み直す(セパレーターのドラッグ・ウィンドウ/パネルの
// リサイズを1箇所で拾う)。段組みを書き換えても lanesGrid 自身の大きさは変わらないので
// 再入しない。jsdom には ResizeObserver が無いので存在するときだけ張る。
export function relayoutPreviewsForResize() {
  if (previewLayoutIds.length === 0) {
    return;
  }
  relayoutLanesGrid(previewLaneCount, previewLayoutIds);
}
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => relayoutPreviewsForResize()).observe(lanesGrid);
}

// 出力ペインは常設(実行前もデバイス毎の空レーンを表示)。レーンはdevicesサイクルから常時同期。
export function updateLanesPlaceholder() {
  lanesPlaceholder.style.display = 'none';
  lanesGrid.style.display = 'grid';
}
updateLanesPlaceholder();

// 実行開始(cleared)で一旦消えても、次のdevicesサイクルで復元される。
// タイル側(deviceTiles.js applyDevices)と対で、devicesに無いレーンは削除して数を同期する。
// 全体レーン(__overall__)はworker無しイベントの受け皿でdevicesに現れないため削除しない。
export function syncLanesToDevices(devices) {
  const deviceIds = new Set(devices.map((device) => device.id));
  for (const [id, lane] of [...lanes]) {
    if (id !== OVERALL_LANE_ID && !deviceIds.has(id)) {
      removeLane(id, lane);
      lanes.delete(id);
    }
  }
  for (const device of devices) {
    ensureLane(device.id, device.name, device.platform, true, device.machineHost);
  }
  deviceOrder = devices.map((device) => device.id);
  reorderLanes();
  updateLaneVisibility();
}

export function applyLaneAction(action) {
  switch (action.type) {
    case 'cleared':
      clearAllLanes();
      break;
    case 'lanesConfigured':
      configureLanes(action.lanes);
      break;
    case 'line':
      appendLaneLine(action.laneId, action.text);
      break;
    case 'workerRunning':
      setTileRunning(action.workerId, action.running);
      break;
    case 'runFinished': {
      const base = t('wvMonitor2.laneLog.runFinished', { passed: action.passed, failed: action.failed });
      const timingParts = [];
      if (action.totalSeconds != null) {
        timingParts.push(t('wvMonitor2.laneLog.timingTotal', { seconds: action.totalSeconds.toFixed(1) }));
      }
      if (action.testSeconds != null) {
        timingParts.push(t('wvMonitor2.laneLog.timingTest', { seconds: action.testSeconds.toFixed(1) }));
      }
      if (action.scenarioTotalSeconds != null) {
        timingParts.push(
          t('wvMonitor2.laneLog.timingScenarioTotal', { seconds: action.scenarioTotalSeconds.toFixed(1) }),
        );
      }
      lanesRunStatus.textContent = timingParts.length > 0 ? base + '(' + timingParts.join(' / ') + ')' : base;
      break;
    }
    default:
      break;
  }
}

export function applyLaneHydrate(snapshot) {
  clearAllLanes();
  if (snapshot.lanes.length > 0) {
    configureLanes(snapshot.lanes);
  }
  for (const laneId of Object.keys(snapshot.linesByLane)) {
    for (const text of snapshot.linesByLane[laneId]) {
      appendLaneLine(laneId, text);
    }
  }
  for (const workerId of snapshot.runningWorkers) {
    setTileRunning(workerId, true);
  }
}
