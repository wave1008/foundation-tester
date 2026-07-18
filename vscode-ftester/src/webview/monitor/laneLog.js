// lanesの読み書きはこのモジュールに閉じる。deviceTiles.jsとはselectedDeviceIds/tiles/
// runningWorkers(いずれも再代入されないMap/Set)を介して相互参照する。

import { MAX_LANE_LINES, OVERALL_LANE_ID, overallLaneName } from "../../runLaneModel";
import { lanesPlaceholder, lanesGrid, lanesSelectionStatus, lanesRunStatus } from './domRefs.js';
import { tiles, selectedDeviceIds } from './deviceTiles.js';
import { t } from '../i18n.js';

// レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
const lanes = new Map();

// devices同期(タイルと同じ配列)のid順。レーンの列順は常にこれに合わせる。
// lanesConfigured(workersReady)はワーカー合流順(Android先行・iOS後合流)で届くため、
// DOM追加順のままだとタイルの並びと食い違う。
let deviceOrder = [];

// lanesGridの子要素をdeviceOrder順に並べ直す(appendChildは既存ノードの移動)。
// deviceOrderに無いid(全体レーン等)は末尾・相対順維持。
function reorderLanes() {
  if (deviceOrder.length === 0) {
    return;
  }
  const rank = new Map(deviceOrder.map((id, index) => [id, index]));
  const ordered = [...lanes.keys()].sort(
    (a, b) => (rank.get(a) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b) ?? Number.MAX_SAFE_INTEGER),
  );
  for (const id of ordered) {
    lanesGrid.appendChild(lanes.get(id).el);
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
function setLaneHeader(headerEl, name, platform) {
  headerEl.textContent = '';
  const pill = document.createElement('span');
  pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
  pill.textContent = name;
  headerEl.appendChild(pill);
}

// updateLabel=trueはdevices同期等のレーン構成時のみ。appendLaneLineから呼ぶ時にtrueにすると、
// フォールバック名(生のworker id)で構成済み表示名を上書きしてしまう。
function ensureLane(id, name, platform, updateLabel) {
  let lane = lanes.get(id);
  if (lane) {
    if (updateLabel) {
      setLaneHeader(lane.headerEl, name, platform);
    }
    return lane;
  }
  const el = document.createElement('div');
  el.className = 'lane';
  const header = document.createElement('div');
  header.className = 'lane-header';
  setLaneHeader(header, name, platform);
  const body = document.createElement('div');
  body.className = 'lane-body';
  el.append(header, body);
  lanesGrid.appendChild(el);

  lane = { el, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
  body.addEventListener('scroll', () => {
    lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
  });
  lanes.set(id, lane);
  updateLaneVisibility();
  return lane;
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
  for (const lane of lanes.values()) {
    lane.el.remove();
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
      lane.el.remove();
      lanes.delete(id);
    }
  }
  for (const info of laneInfos) {
    ensureLane(info.id, info.name, info.platform, true);
  }
  reorderLanes();
  updateLaneVisibility();
}

export function updateLaneVisibility() {
  const allIds = [...lanes.keys()];
  const activeIds = selectedDeviceIds.size > 0
    ? allIds.filter((id) => selectedDeviceIds.has(id))
    : allIds;
  const columns = Math.max(1, activeIds.length);
  lanesGrid.style.gridTemplateColumns = 'repeat(' + columns + ', minmax(0, 1fr))';
  for (const [id, lane] of lanes) {
    lane.el.style.display = activeIds.includes(id) ? 'flex' : 'none';
  }
  lanesSelectionStatus.textContent = selectedDeviceIds.size > 0
    ? t('wvMonitor2.laneLog.selectedCount', { count: selectedDeviceIds.size })
    : t('wvMonitor2.laneLog.allWorkers');
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
      lane.el.remove();
      lanes.delete(id);
    }
  }
  for (const device of devices) {
    ensureLane(device.id, device.name, device.platform, true);
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
