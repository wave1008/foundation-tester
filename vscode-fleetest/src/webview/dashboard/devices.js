// devices.js
// 「デバイス別」セクション(#section-devices、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)。OS 別(devices.byPlatform)とデバイス別(devices.byWorker)の2表を描く。
// worker 行は insights.js の deviceBias リンクから revealWorkerRow() で参照される
// (完全一致だけで結ぶ。一致しなければ insights.js 側がリンクにしない)。

import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { revealSection } from './domUtil.js';
import { formatDurationSeconds, formatPercentInteger } from './format.js';

const UNKNOWN_WORKER = '(unknown worker)';
const COLLAPSE_LIMIT = 15;

const section = document.getElementById('section-devices');
const platformBody = document.getElementById('table-devices-platform-body');
const workerBody = document.getElementById('table-devices-worker-body');
const toggleBtn = document.getElementById('devices-toggle-all');
const emptyEl = document.getElementById('devices-empty');

let expanded = false;
let currentWorkers = [];

function workerLabel(worker) {
  return worker === UNKNOWN_WORKER ? t('wvDashboard.devices.notRecorded') : worker;
}

function workerRow(row) {
  const tr = document.createElement('tr');
  tr.dataset.worker = row.worker;
  const nameCell = td(workerLabel(row.worker));
  if (row.worker === UNKNOWN_WORKER) {
    nameCell.title = t('wvDashboard.devices.notRecordedTitle');
  }
  tr.append(
    nameCell,
    tdNum(String(row.runs)),
    tdNum(formatPercentInteger(row.successRate)),
    tdNum(formatDurationSeconds(row.avgDurationMs)),
  );
  return tr;
}

function renderWorkerRows() {
  clearChildren(workerBody);
  const rows = expanded ? currentWorkers : currentWorkers.slice(0, COLLAPSE_LIMIT);
  for (const row of rows) {
    workerBody.appendChild(workerRow(row));
  }
  if (currentWorkers.length > COLLAPSE_LIMIT) {
    toggleBtn.style.display = 'inline-block';
    toggleBtn.textContent = expanded
      ? t('wvDashboard.devices.showLess')
      : t('wvDashboard.devices.showAll', { count: String(currentWorkers.length) });
  } else {
    toggleBtn.style.display = 'none';
  }
}

toggleBtn.addEventListener('click', () => {
  expanded = !expanded;
  renderWorkerRows();
});

export function renderDevices(devices) {
  clearChildren(platformBody);
  for (const row of devices.byPlatform) {
    const tr = document.createElement('tr');
    tr.append(
      td(row.platform),
      tdNum(String(row.runs)),
      tdNum(formatPercentInteger(row.successRate)),
      tdNum(formatDurationSeconds(row.avgDurationMs)),
    );
    platformBody.appendChild(tr);
  }
  expanded = false;
  currentWorkers = devices.byWorker;
  renderWorkerRows();
  const empty = devices.byPlatform.length === 0 && devices.byWorker.length === 0;
  emptyEl.style.display = empty ? 'block' : 'none';
}

/** insights.js が deviceBias のリンク可否を判断するための存在チェック(副作用なし)。 */
export function hasWorkerRow(worker) {
  return currentWorkers.some((r) => r.worker === worker);
}

/** insights.js の deviceBias リンククリックから呼ぶ: 該当行までスクロールして一時的に強調する。
 * 折りたたまれていれば展開してから探す。一致しなければ何もしない。 */
export function revealWorkerRow(worker) {
  if (!expanded && currentWorkers.findIndex((r) => r.worker === worker) >= COLLAPSE_LIMIT) {
    expanded = true;
    renderWorkerRows();
  }
  let target = null;
  for (const row of workerBody.children) {
    if (row.dataset.worker === worker) {
      target = row;
      break;
    }
  }
  if (!target) {
    return;
  }
  revealSection(section);
  target.classList.add('row-highlight');
  setTimeout(() => target.classList.remove('row-highlight'), 1500);
}
