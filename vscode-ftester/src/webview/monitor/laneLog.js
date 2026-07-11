// laneLog.js
// 出力ペインの「ログレーン」(worker/デバイスごとの実行ログ表示欄)を担う。
// lanes(レーン id -> DOM/自動スクロール状態)は実際に読み書きするのはこのモジュールの関数群
// だけなので、このファイルに閉じている(deviceTiles.js とは selectedDeviceIds/tiles/
// runningWorkers を介して相互に参照し合う。いずれも再代入されない Map/Set の中身を
// 変更するだけなので import 境界をまたいでも問題ない)。

import { MAX_LANE_LINES, OVERALL_LANE_ID, OVERALL_LANE_NAME } from "../../runLaneModel";
import { lanesPlaceholder, lanesGrid, lanesSelectionStatus, lanesRunStatus } from './domRefs.js';
import { tiles, selectedDeviceIds } from './deviceTiles.js';

// レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
const lanes = new Map();

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

// レーン名はデバイスタイルのタイトルと同じテキスト・同じ装飾(色付きピル)にする。
// platform 不明(全体レーンやフォールバック)は中立色のピル。
function setLaneHeader(headerEl, name, platform) {
  headerEl.textContent = '';
  const pill = document.createElement('span');
  pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
  pill.textContent = name;
  headerEl.appendChild(pill);
}

// updateLabel=true は workersReady/hydrate/デバイス同期によるレーン構成時のみ。
// 行追加(appendLaneLine)からの呼び出しで true にすると、フォールバック名(生の worker id)で
// 構成済みの表示名を上書きしてしまう。
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
  const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? OVERALL_LANE_NAME : laneId, undefined, false);
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
    ? '選択中' + selectedDeviceIds.size + '台を表示'
    : '全ワーカー';
}

// 出力ペインは常設で、実行前でもデバイス毎の空レーンを表示する(プレースホルダー文言は
// 表示しない)。レーンはモニターの devices サイクルから常時同期する。
export function updateLanesPlaceholder() {
  lanesPlaceholder.style.display = 'none';
  lanesGrid.style.display = 'grid';
}
updateLanesPlaceholder();

// モニターのデバイス一覧に合わせて空レーンを用意する(既存レーンはそのまま。
// 実行開始(cleared)で一旦消えても、次の devices サイクル(interval秒毎)で復元される)。
export function syncLanesToDevices(devices) {
  for (const device of devices) {
    ensureLane(device.id, device.name, device.platform, true);
  }
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
    case 'runFinished':
      lanesRunStatus.textContent = '完了: 成功 ' + action.passed + ' / 失敗 ' + action.failed;
      break;
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
