// devices.js
// 「デバイス別」セクション(#section-devices、monitorHtml.ts の renderDashboardPanel() が静的
// スケルトンを持つ)。デバイス別(devices.byWorker)の表を描く(byPlatform は描かない)。
// worker 行は insights.js の deviceBias リンクから revealWorkerRow() で参照される
// (完全一致だけで結ぶ。一致しなければ insights.js 側がリンクにしない)。

import { t } from '../i18n.js';
import { clearChildren, td, tdNum } from './domUtil.js';
import { revealSection } from './domUtil.js';
import { formatDurationSeconds, formatPercentInteger } from './format.js';

// worker 欄を持たない古い記録の束(CLI の RunResultsQuery.unknownWorkerLabel)。どの台か言えないので出さない
const UNKNOWN_WORKER = '(unknown worker)';
const COLLAPSE_LIMIT = 15;

const section = document.getElementById('section-devices');
const workerBody = document.getElementById('table-devices-worker-body');
const toggleBtn = document.getElementById('devices-toggle-all');
const emptyEl = document.getElementById('devices-empty');

let expanded = false;
let currentWorkers = [];

function workerRow(row) {
  const tr = document.createElement('tr');
  tr.dataset.worker = row.worker;
  tr.append(
    td(row.worker),
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
  expanded = false;
  currentWorkers = devices.byWorker.filter((row) => row.worker !== UNKNOWN_WORKER);
  renderWorkerRows();
  const empty = currentWorkers.length === 0;
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
